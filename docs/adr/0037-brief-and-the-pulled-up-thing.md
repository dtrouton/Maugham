# ADR 0037 — Brief, the pulled-up thing and the fold: what the right column is about, and what hangs under a piece

**Date:** 2026-11-20 · **Status:** Accepted (plan 3 of a multi-plan milestone; see "Not yet built"; brought true at the final fix wave) · **Milestone:** shell-p3-brief-and-the-pulled-up-thing (branch `claude/shell-without-personas`) · **Design:** `docs/superpowers/specs/2026-11-16-subject-resolve-brief-shell-design.md` ("Brief", "The pulled-up thing", "The fold") · **Builds on:** [ADR 0035](0035-the-subject-not-the-persona.md), [ADR 0036](0036-to-resolve.md) · **Cited by:** the amendment to [ADR 0027](0027-the-compiler-and-the-editor-boundary.md) §1 (plan 5)

## Context

After [ADR 0036](0036-to-resolve.md) the right column held To resolve beside a picker of older panes: the Inspector (a piece's line, tags, targets, links, publishing), the Intent pane and the three long statements, References (the shelf of pins), the study column (one pin, read-only, in place of the pane), History, Translation and the Department desk. A writer asking "what is this held to?" had to know which pane carried the answer, and what a piece owned (its research, cards, links) was a shelf in one pane and a field list in another.

The design replaces the picker with three positions and gives the tree's piece row the material a piece owns.

## Decision

The right column has three positions, in one order, selected by ⌘1, ⌘2 and ⌘3: **To resolve**, **Brief** and **Pulled up** (`RightColumnPosition`, `RightColumnControl`). One position is remembered per window (`UIState.rightColumnPosition`). What each shows is one pure answer, `RightColumnContent.of`, rendered by one exhaustive `switch` in `RightColumn`.

### What each position shows

| Position | Faces / state | Shows |
|---|---|---|
| To resolve | translation review on, the faces' piece open | `TranslationReviewPane` (interim) |
| To resolve | an edition is the faces | `DepartmentPaneHost`, the desk (interim) |
| To resolve | anything else | `ResolvePane` ([ADR 0036](0036-to-resolve.md)) |
| Brief | a piece; a Part; the Book; an edition; a Collection reference piece; anything else | the piece's Brief; the Part's; the Book's; the edition's; "This piece belongs to another project"; an empty state naming what Brief holds |
| Pulled up | something is pulled up (`subject.beside`) | that item with its details, under `BesideHeader` (Open in Centre, Close); with the canvas the centre and a card, region or line selected on it, the canvas's details instead (below) |
| Pulled up | nothing pulled up; the centre holds the canvas, a figure, a research item or a Collection reference piece | the centre's own details (`RegionInspectorPane`, `FigureInspector`, `ResearchSubjectInspector`, `ReferencePieceInspector`) |
| Pulled up | nothing pulled up and nothing of the above | "Nothing pulled up" |

A screenplay's Book Brief is its script's Brief, by the rule To resolve applies (`ResolveScope.of`, [ADR 0036](0036-to-resolve.md)), which Brief asks rather than restates. The Pulled up position is **hidden, never disabled, while it would show nothing** (`RightColumnContent.offersPulledUp`); a window restored on it with nothing to show still draws the selected segment over "Nothing pulled up". The control is three plain buttons rather than a segmented `Picker`, because a picker cannot carry a middle-truncated title or a dot per segment; the title is drawn at 200pt and wider (`RightColumnControl.titleFloor`), below which a segment is its icon. The unread dot sits on To resolve; the "proposed" signal is the dot on Brief.

**Why one answer.** The old picker's order, offers and carried segments were four rules agreeing by accident (`DetailSegmentOrderTests`). One value cannot disagree with itself, and the mounting census (`RightColumnMountingTests.test_theControlIsTheOneOrderUnderEverySubject`) measures it under every subject.

**The position after a subject change** (`RightColumnContent.positionAfterSubjectChange`) is the first of: something newly pulled up, or the item already pulled up becoming the part clicked last again ("show me this" must show it, even when it is already there), shows Pulled up; Pulled up left with nothing to show returns to the face before it (`previousFace`); the faces moving onto the canvas shows Pulled up (the canvas's details); otherwise unchanged. A restore does not run it.

### Brief

Brief shows what the faces' subject is **held to**, in the writer's own words (`Maugham/Views/Brief/`). `BriefScope` is its own type, not `ResolveScope`: To resolve folds the Book and a Part into one case, and Brief must tell them apart (the Book has an intent and gathers every origin; a Part has neither).

- **A piece:** the line; **Going for** (the intent); **Decided** (its dated decisions, newest first, the newest three showing and the rest under a disclosure); then two quiet lines, **From the book** and **What Claude has read** (readings the writer has not confirmed; Confirm and Correct live here). A Collection's loose piece also carries a caption at the head naming its format, Prose or Screenplay: the one place that says what the piece is held to, now that the Inspector's kind label is gone.
- **A Part:** it has no intent and no line, so Brief gathers its chapters' decisions, one section per chapter that has any, each titled with the chapter and a button to that chapter's Brief; then From the book.
- **The Book:** the book's intent, every standing decision under one filter by where it was made (the book, a piece, What I've Learned, First Reader, an edition), the long statements (What I've Learned, First Reader, Visual Language) as links that pull up, and what Claude has read of the book.
- **An edition:** its edition brief (the same `StatementPane` the desk's Edition Brief door opens), who is cast for it (read here; changed only on the desk), and the book's Visual Language, which pulls up.
- **Another project's piece:** a line saying so. **Anything outside the manuscript** (the Inbox, the Canvas, the Palette, research, a figure): a line naming what Brief holds.

**Reading without loading.** Brief never loads a manuscript `Document` (`BriefReaderTests.test_noBriefSourceLoadsAManuscriptDocument` reads the folder). It reads the line from `StructureItem.synopsis`, the intent and decisions through `ProjectStore.statementText(of:)`, the check's reading from the diagnostics store, and live paragraph ids from the open document or the derived cache. **So Brief edits a piece that is not open.** The line is a manifest write, asked of the same permission as a rename (`TreeStructureVerbs.mayRestructure`). The intent, a decision and Confirm are statement writes, asked of the intent's own posture. Offers are hidden, never disabled, and Lock does not apply to Brief. Plan 2's rule (manuscript verbs act only on the open piece) is untouched.

**The line.** Above the prose the line falls back to the effective intent's opening, as it did. The cards, the outline and the MCP outline listing fall back to the piece's own intent only (`BriefLine.display`). The strip stays a String and a Bool; its click posts an event whose receiver shows the open piece's Brief (`MaughamEvent.postBriefOfTheOpenPiece`), so the strip takes no closure.

**Showing a Brief mints nothing.** The intent's empty editor mints the statement on the first keystroke.

**The line saves without a blur** (final wave): on Return, focus loss and the view leaving, and also 500 ms after the last edit, through `DocumentStore.scheduleBriefLine`. A pending line is written by `flushPendingSave`, the door ⌘S, a window's close and ⌘Q (`ProjectSession.closeForQuit`) already settle every debounced editor through, so a line typed and never left survives ⌘Q.

**What will not read is said** (RULING-54; final wave). An intent whose read throws is named in `BriefSnapshot.unreadable`, and Going for draws one line, "This intent can't be read.", with no editor and no Open in Centre over it; never "No intent yet." and never the empty prompt. Decided says the same for that statement, a Part keeps a section for that chapter saying so, and the Book's Decided names every origin that would not read.

### The clause marks (owner's ruling, 2026-11-16)

The check reads each clause of the intent and says that the draft holds it, strains against it or is silent on it. Brief draws that reading on the writer's own sentences in Going for: a **solid underline** where the draft strains, a **dotted underline** where it is silent, nothing where it holds. Denver ruled these marks to be **within constitution must-not #2 and [ADR 0027](0027-the-compiler-and-the-editor-boundary.md) §1**, on four terms that this ADR makes the test:

1. **A mark carries no model text.** It is drawn from `ClauseMark.Kind` alone, over the writer's characters; its legend is two app constants; the check's quote is never drawn (`GoingForTests.test_aMarkCarriesNoModelText`). What the check said is shown only in To resolve, where it always was.
2. **Marks show only while Brief is in the right column.** Never in the centre item's cover, never on the line above the prose (`IntentStrip` keeps its String-and-Bool input), never in the editor. The right column is the constitution's own read-only companion surface; the editor and its chrome stay free of anything a model produced.
3. **The snapshot rule.** A run's marks apply only while the run's `intentSnapshot` hashes to the statement's current text (`ClauseMarks.applies`). Edit the intent and the marks go until the next check: they never land on the wrong sentence.
4. **The first-occurrence rule.** Each clause takes the first unmarked occurrence of its quote, strains before silences and the longer quote first, so marks never overlap. A quote found nowhere marks nothing. Matching folds curly quotes, whitespace and case, because a model quoting a sentence straightens its quotes and reflows its whitespace (cost: a rare false match between two sentences that differ only in case or quotes).

A solid mark is a link: its click shows To resolve on the finding that mark stands for (`ClauseMarks.jump`, `ResolveRequest.focusFinding`, matched by run id, kind and the identical quote). A dotted mark asks nothing. Going for has two faces: while the marks apply, the essay reads as prose with the marks and an Edit button; otherwise the statement's editor sits there. The reading view draws the intent as the editor shows it and never recolours the writer's words: a mark is an underline, never a tint.

### Answering moves an item across

Each verb that takes something raised in To resolve and files it under what the subject is held to (Answer, Add to intent, Keep as lesson, This is a choice, Make it a rule, Confirm) says where it went, in one quiet line from the write's own return value (`RulingPerformer.rule` returns the `FiledDestination` it wrote; `FiledUnder`, `FiledNotice`). The line names the destination and nothing else; it never quotes the check or Claude. It stays six seconds or until the next filing replaces it.

- **The line is a link whenever it names a Brief**, including from the Book's list to a piece's intent, where the faces move. This overrides the plan's first reading (a link only when the destination is in the faces' own Brief): the destination being out of sight is when the link earns its place.
- **An item already in the ledger says "Already in What I've Learned"**, not "Filed under".
- **The item leaves To resolve on the next read and appears under Decided in Brief.** The notice outlives the row that raised it, and an Answer from a Book list names the piece rather than "this chapter". In a collection the whole-piece group is titled "Whole piece" so it agrees with "this piece's intent".
- **A solid mark whose strain never had an item** says "The last check flagged this sentence. There is nothing to act on here." and never "Settled". A mark whose finding is no longer listed (answered, replaced by a newer check, dropped when its anchor text changed) says the settled line.
- **A statement mark's Open moves the faces** to the statement's own scope (`MarkDestination.brief`), then shows Brief, as the filed line does. `open` does not move.
- **A bulk bar inside a Book or Part list acts only over the one piece that is open** (`ResolveVerbGate.bulkDocId`), and `runBulk` intersects the ids with that `Document`'s own notes before acting.

### The fold

A piece's row in the tree has a fold holding what the piece owns or draws on (`PieceFoldIndex`, `BinderPieceFold`): its research, the canvas's cards bound to it (scraps, owned pictures, research cards), its palette pins, the figures it owns, and its links **in both directions**. The incoming links ("Linked from") are marked as such: **backlinks are kept**, as a controller's amendment before the owner's review. The design sends links to the fold and does not say one direction only, and dropping the Inspector's "Linked from" would have lost a capability.

- **Nothing here derives membership of its own.** Research and canvas material is the References shelf's resolver (`PinnedReferenceResolver`), which already drops what the manifest can no longer resolve; ownership of research is the tree's own fold (`TreeSectionDerivation.pieceFold`); a figure's owner is `ProjectStore.figureNoteOwners`; a backlink is `PieceLinks.linkedFrom`.
- **Built once per key, never per row.** The index is built in the hosts' `.task`, keyed on `PieceFoldIndex.Key` (the manifest's modified time, the scene revision and the canvas's node-added count). A research note dragged into a fold, a card bound on the canvas and a figure's owner changing each move the key. Past six entries the fold groups, with counts (`groupsAbove`).
- **A bound region is one row** (owner, 2026-11-20, from the hand check: "if I add a region I get the region as super group which can be opened then in right panel"). A canvas region bound to the piece is one fold row (its title, a region glyph, its card count) with its own chevron opening to its cards in the shelf's order; a card bound to the piece itself stays a plain row. The shelf's sections now carry their region's id (`PinnedSection.regionId`), so a region is told from the loose cards by its id, never its title (this fixes the parked "region titled Cards" minor). A region row counts as one entry toward the six and lives inside the Cards group. A palette card in a region still lists under Palette, where the fold has always put palette cards. Its chevron is remembered as the groups' are (`expandedFoldRegions`, open ids only, not persisted). Its row's click pulls the region up (below) by the card rows' route (`ClickRule.pullUp`); a second click puts it away; Open in Centre is the row's menu.
- **Linked and owned look different.** A Collection piece's fold holds research in the piece's own folder, drawn as the Research section draws it. A novel chapter's fold holds links to shared research, quieter, with a trailing link glyph, flat and never renamed there.
- **A row acts by one rule.** Research and figures are `List` tags that take the centre as anywhere in the tree; a card or palette pin is pulled up beside by a `Button(.plain)` (tripwire 9) and a second click puts it away; a link travels to its piece; a double-click or Open in Centre always opens in the centre. The chevron shows only when the piece has entries.
- **A single-document project keeps its fold** (a short story's one document: chevron and grouped counts), because the fold is where a piece's material lives in every project type. Cost: one chevron on a single row; one line to remove.
- ⌘⌥E opens the faces' piece's fold in the tree (else the open piece's), opens the Parts above it (`BinderTreeSectionsState.expandedStructureGroups`, `groupExpansion(of:)`; not persisted, as the folds are not), shows a hidden tree, and scrolls the row into view. Its menu item is disabled with no piece.

### The pulled-up thing

One thing at a time is pulled up beside the centre (`PulledUp`, `WindowSubject.beside`, widened from a research item): a research item (note, table, PDF, palette card), a figure, a canvas card (a scrap or a picture), a canvas region, What I've Learned, First Reader, Visual Language, a piece's History, or the project's History (where no piece is faced or open). It persists across subject changes until closed (Close, or Esc through `WindowEscapeArbiter`, ahead of the centre item's cover; `PulledUpEscape`). Pulling a second thing up replaces the first.

- **Open in Centre MOVES it.** The pulled-up position empties, for every kind: a research note, a figure, a card, a statement, History. Closing the centre item does not pull it back up; to read an intent beside the text again the writer pulls it up again. (The first reading kept a placeholder behind; one rule for every kind is cheaper to carry.) A statement or History opens in the centre as a cover (below), over the piece it names, or the Book.
- **Never a second editor on what the centre shows** (`PulledUpView.centreShows`, the one spelling). Where the centre already shows the item, the pulled-up view draws the read-only form or the "open in the centre" line. A card on the palette wall is never edited beside it too, and the pulled-up editor and the wall's editor settle a card's pending edit before the other seeds (`EditorHandOverTests`).
- **Editable beside:** a research note and a palette card (the note is a second editor, `isSecondEditorInItsWindow`), a table's grid, a statement. **Read-only beside:** a canvas card, by the owner's answer, because a card's words live in the canvas's shared text storage, and a second editor beside the manuscript would put them at risk (tripwires 26–28). A scrap beside follows the canvas's own typing; Open in Centre opens the canvas and selects the card; a card that is no longer on the canvas shows a missing state with Close. Lock covers a pulled-up note, card, table and figure exactly as in the centre; a statement asks its own posture.
- **A region beside reads down the column** (owner, 2026-11-20; `PulledUpRegionView`): its title in the header with Open in Centre (the canvas opens and selects the region, `CanvasModel.revealAndSelect`) and Close; then its cards in the canvas's visual order, the one ordering the shelf and the fold use (`PinnedReferences.readingOrder(ofRegion:in:)`): a scrap's whole words, an owned picture scaled to the column, a research or palette card (a table included) as a title row whose click pulls that item up in the region's place. A region promoted to a note shows the note first. Read-only, for the card's reason, and following the canvas's typing as a scrap beside does. The view is a leaf that reads the scene in a `.task` keyed on the structural revision; the control reads the region's title the same way (the store alone cannot name it). A region no longer on the canvas shows the missing state with Close, and the subject sweep puts it away, as for a card. Lock, Esc and the canvas's cover need nothing new: a region is read-only, Esc and the cover are about any pulled-up thing.
- **Hidden when it would show nothing** (above). With nothing pulled up, the position shows the centre's own details, so the canvas's selected card or region is not lost with the old Inspector.
- **The canvas's selection covers what is pulled up** (owner, 2026-11-20, from the hand check: a region selected under a pulled-up note, and ⌘3 "did nothing" because the note held the position). While the canvas is the centre and something is pulled up, the position shows the canvas's details (`RegionInspectorPane`) while the canvas has a selection, and the pulled-up thing again once it clears (`RightColumnContent.canvasDetailsCover`, pure). Covering is drawing only: `subject.beside` is untouched, the column's answer stays `.pulledUp(_)`, and the control keeps the pulled-up thing's title. The selection is read one leaf down (`CanvasDetailsCover`), never by `RightColumn` or the window: `CanvasModel.selection` is its own stored property, written on a click, drop, key or delete and never per drag frame (tripwire 30). Escape over the cover declines (`PulledUpEscape`, asked at event time), so it passes down the order and never puts away a note the writer cannot see.
- **It is never what the tree selects or the canvas lights** for a statement or History (neither is a tree row); a pulled-up research item or figure is the tree's `beside` outline as before.
- **A stored subject reads back across the change.** `PulledUp` keeps `BinderSubject`'s `{"kind","id"}` shape for the two kinds they share, so a `beside` written by plans 1–2 reopens; the kinds that are not tree rows (a region among them, `{"kind":"canvasRegion","id":…}`) are stored under a new key a previous build ignores; an unknown kind reads as nothing beside (tripwire 11). `UIState` no longer reads the old `detailSegment` key at all.

### The centre item and the keys

A piece's intent, a Book statement or a piece's History can be opened in the centre as a **cover** over the manuscript editor (`CentreItem`, `CentreItemCover`). `EditorHost` stays mounted under every cover (tripwire 6), so the cover owns the keys, or the manuscript would take keystrokes the writer cannot see.

- **While the editor is covered, the manuscript's text view is never first responder** (`CentreKeys`). The cover claims the keys for its own editor on arrival and on each item change; whatever re-asserts the manuscript (a load, a find, a navigation) is moved off; a closing cover hands back only the keys it held. A view inside the manuscript (a figure-grid cell editor, a review composer, the find bar's Replace) counts as the manuscript, found by ancestry.
- **A place closes the cover first.** `ManuscriptNavigation.go` closes the centre item before any place lands; an annotation jump with no paragraph and a double-click on the open piece's own row close it too.
- **One question: is the manuscript the editor the writer can see?** (`ProjectWindow.manuscriptIsVisible(route:)`, reached by an editor through `CentreKeys.manuscriptIsVisible(holding:)`). Every manuscript-writing entry point that does not go through the text view's own keys asks it: the Insert commands and Format ▸ Table through `manuscriptCommandContext`. `EditorWriteCommandCensusTests` classifies each editor observer as a writer or not by name, with a planted offender, so a new one cannot be added unasked. Only the centre item's cover had the hole; every other cover stands where `EditorHost` has no document or is unmounted.
- **Esc does not close the cover while the keys are in its statement editor** (the arbiter's text-editing rule): the Close button is the way out.
- **Every statement host that can stand beside a centre cover asks `statementIsInTheCentre`** before mounting (Brief's Going for, the pulled-up statement), so the placeholder is decided before the mount, never discovered by a refusal. An edition brief's host (`BriefEditionView`) does not ask: an edition brief is never a centre item.
- **History's Rewind acts only on the open piece** (final wave, C1). A pulled-up History keeps its piece while the faces move, so every rewind post carries its piece (`HistoryPane.rewindPayload`, as `jump` already did) and the receiver presents for that piece only while its `Document` is the one open (`RewindModifier.rewindTarget`), never for the faces. Rewind… and each row's *Rewind to before this…* are hidden where the History's piece is not open; a Restore pressed after its piece closed under the sheet says so. The project's History offers no Rewind (it has no piece) and keeps its checkpoint Revert, the picker's own verb.

### The undo model, as built

Five review rounds settled it. ADR 0023 stands: one undo stack per window, no cross-subject undo.

1. **The cover's arrival drops the window's undo stack** the way a piece change does (`EditorCoordinator.dropTheUndoStack`, the one function `detach` also calls; called from `CentreKeysView` on a centre-item cover's arrival edge). Without it ⌘Z from the tree under the cover would undo the hidden chapter. The guard view therefore owns no undo, and a History-cover Rewind is ⌘Z-undoable again. Cost: opening an intent or History in the centre clears the chapter's typing undo, as switching chapters does.
2. **A statement verb registers on the first responder's own undo manager.** The chooser walks the responder chain from the first responder: the first statement editor on it (a second editor with a private manager, which answers `undo:` and `redo:` itself) gives its manager; anywhere else (the manuscript, a research note's editor, the tree, a field, nothing) the window's. It is chosen once, at the press (`StatementVerbUndo`).
3. **A write is undo-coherent only when that manager is the statement's own holder.** Each write carries its own `StatementWriteUndo` (`plain`, `verb(on:)`, `replay(on:)`), passed into `mutateStatementText` and never stored, so no write can see another's; a census fails on a stored one. Adopt, Revoke and Edit ruling use it.
4. **A forward verb clears only the editor's typing undo, by its text-storage target** (`EditorTypingUndoManager.removeTypingActions`), because typing registers range-bearing actions that a buffer replace makes stale, while a verb's own inverse is range-free. So ⌘Z ⌘Z over two verbs undoes both in order. A plain write still drops the holding editor's whole stack.
5. Statement typing is ⌘Z-undoable in the statement's own editor, and ⌘Z in a statement pane no longer undoes the manuscript (a defect already at the shipped base).

### The statement host's open gate and the foreign arrival

Brief's intent, the centre cover and a pulled-up statement can name one statement, and Brief keeps an intent open for long stretches, so the host's lifecycle matters:

- **One host, one `Document`.** `StatementEditorHost.gateArrival` refuses a second binding. The load re-asks the registry under the gate and waits (`waitForStatementRelease`) on a statement another host holds. A mint that finds the statement already held deposits into the live `Document` and the pane waits and binds (`LoadOutcome`: `bound`, `deliveredElsewhere`, `notBound`).
- **A host lets go under the gate** (`ProjectStore.closeStatementDocument`: lock, forget, close, unlock), because a close flushes the typing burst and used to run detached, so a second host could open a second `Document` on the path while the first flushed (duplicate ops, a stale paragraph over the flushed one, a forked chain). Order pinned by `StatementGateOrderTests`.
- **An open statement re-reads on a foreign arrival.** The `.opLog` arm of `DocumentStore.presenterDidChangeSubitem` re-reads an open statement through `reReadAfterExternalChange`, as the manuscript arm does. Before, an open intent kept stale paragraphs and the writer's next keystroke in a paragraph a peer had changed wrote over the peer's words (ops are whole-paragraph, later ids win). It bumps `statementTextRevision` only when the arrival changed something (our own flush is the re-read's echo); a closed statement's arrival bumps once (`StatementPeerArrivalTests`). The bump's callers are a census (`BriefLineTests.statementTextBumpSites`).

### The keys

⌘1, ⌘2 and ⌘3 are the positions. The old pane keys keep their letters and land where each pane's content lives now (owner's answer, 2026-11-18), each through a receiver that shows a hidden column (`MaughamEvent`, tripwire 21):

| Key | Does |
|---|---|
| ⌘⌥A, ⌘⌥D, ⌘⌥T | To resolve on Rounds, Checks, Mine |
| ⌘⌥I, ⌘⌥N | Brief |
| ⌘⌥G, ⌘⌥Y, ⌘⌥V | pull up What I've Learned, First Reader, Visual Language |
| ⌘⌥H | pull up the faces' piece's History, or the project's where no piece is faced or open |
| ⌘⌥E | open the faces' piece's fold in the tree (and the Parts above it; shows a hidden tree) |
| ⌘⌥L, ⌘⌥K | To resolve (where translation review and the desk show); ⌘⌥L outside review adds one line saying how review is entered, which stands until the writer moves on |

`RightColumnMountingTests.test_eachOldPaneKeyLandsWhereTheMapSays` and `test_everyPositionAndPullUpHasAMenuShortcut` pin the map.

### Interim homes

Until plan 4 builds an edition's faces and the piece-in-a-language view, the Department desk shows in To resolve while an edition is the faces, and the translation review pane shows there while translation review is on: today's views, mounted unchanged in the position the design gives their successors (owner's answer, 2026-11-18). Without them publishing and translation review would have no home.

**The interim loss** (owner's decision, recorded at the final wave): while the desk or the review shows in that position, To resolve's own list is unreachable, so ⌘⌥A, ⌘⌥D and ⌘⌥T select the position and DROP their filter (never left to fire on a later mount, `ProjectWindow.positionAsk`). Plan 4 closes it.

### Where each old Inspector field went

| Was | Now |
|---|---|
| Written by | To resolve's head, under the pass ladder, where a piece has several writers |
| Pass ladder | To resolve's head |
| Synopsis | Brief's line |
| Intent row | Brief's Going for; the full pane is Open in Centre |
| Tags | a Tags column in the Outline view (read) and **Tags…** in the piece's row menu |
| Word target and page target | the status line under the text: its right label is a menu (Set Word Target…, Set Page Target…, Clear Target), and **Target…** is in the row menu so a target is settable with the status bar hidden. A screenplay's page target is the project's |
| Links out | the fold; **Add Link…** in the row menu; Remove Link on an outgoing link |
| Linked from | the fold, marked incoming |
| Publishing (table of contents, start on, title override) | **Publishing…** in the row menu, where publishing is set up; kept after plan 4 as the per-piece twin of the edition's Status column |
| A screenplay script's Tags, Target and Publishing | the same items in the script row's menu in the Scenes list |
| A Collection loose piece's kind label | the caption at the head of its Brief |
| A reference piece, research, figure, canvas details | Pulled up with nothing pulled up (the centre's details) |
| A group's caption ("Select a document inside this group…") | gone with the pane; a Part's Brief has its own empty states |

The target field is a String that commits what was typed on Set, Return and focus loss, and Escape cancels (noted by a key-down observer before the popover's own Escape closes it, so the disappearance does not commit; `PieceTargetField.EscapeNote`): a numeric field commits only on Return or focus loss, so Set alone would have written the pre-edit value. The status line measures the piece **open** in the centre, not the faces' piece (it took the target from the faces before, so a Book on the faces over an open chapter showed the editor's count against no target).

### The permission change

**Tags, targets, links and publishing now ask restructure permission** (`TreeStructureVerbs.mayRestructure`; a screenplay's project-level page target asks the project stream's `.restructure`). They are manifest or structure writes, and the line beside them already asks it. The Inspector asked nothing for them, so a reviewer or translator who could set them there cannot now: they are hidden, never disabled. For Publishing this narrows who may change a piece's publish settings to the book's author or the piece's own author. **This stands as built and awaits the owner's confirmation.** A Collection's loose pieces gain Tags… and Add Link… (the old pane never offered them there).

### A Core change that directs retranslation

`RulingsSection.parseItem` now reads a comma-less `— ruled <date>` as dated with no provenance, the form `lineText` writes for exactly that ruling, so it must read back dated. A dated ruling IS dated, and directing retranslation is what a dated ruling does: `BriefingDoctrine.isDirected` now honours it (`BriefingDoctrineTests.test_aDatedDirectiveWithNoProvenanceDirects`). **Cost:** an existing project with such rulings may see a translation marked stale once. Core changed, so core and phone gates ran.

## Gone by design

- The pane picker and `DetailSegment`, with `DetailPaneToggle`, `postDetailSegment` and `UIState.detailSegment`.
- The Inspector (`InspectorView`, `PieceInspector`, `IntentAffordanceRow`, `InspectorLinksSection`): each field has a home above.
- The Intent, Visual Language, What I've Learned and First Reader panes as picker members: they are Brief's Going for and the long statements pulled up or opened in the centre. The "Open Intent" row is gone because Brief shows the intent itself.
- The References pane and its empty state naming two ways to pin: the shelf is a piece's fold, and an empty fold has no chevron. The shelf's thumbnails too: a tree row is one line (tripwire 4), and an image is seen by pulling it up; the fold's rows take `CanvasItemFacts`' glyphs.
- The study column (`AssistantColumn`): one pin, read-only, ended by any newer act. The pulled-up thing persists until closed, and a research note or palette card is editable there.
- The History, Translation and Department panes as pickers: History is pulled up, the other two are To resolve's interim answers.
- A selected group showing the project's intent: it shows the Part's Brief.
- The Inspector's debounced draft (it saved every field together 500 ms after any edit): each home writes on its own commit. Brief's line keeps the 500 ms debounce of its own (above), so ⌘Q never loses it.
- The retired picker, study-column, References and Inspector suites: each assertion that policed behaviour that still ships moved onto the live code (the mapping is in the task report), and the presentation rule is `RightColumnMountingTests.test_escapeClosesThePulledUpThing`.

## Parked, then triaged at the final wave

**Done in the final wave:** a failed promotion no longer leaves a statement host over a closed `Document` (the promotion holds the intent's open gate to its end; a host whose `Document` is withdrawn from under it drops to its placeholder and loads again under the gate, `StatementEditorHost.wasWithdrawn`); a trust change (admission, revocation, *Theirs*, a registry arrival) forgets the table of, and re-reads, open statements as well as manuscripts (`DocumentStore.everyOpenDocument()`, the one union, census in `TrustReReadsStatementsTests`); the verb-undo tests use `groupsByEvent = false` and explicit groups instead of a private selector; `StatementVerbUndo.manager(window: nil)` asks the key window's chain; a test pins that another statement's typing survives a verb and its undo.

**The two intermittents:** `test_aStatementMarkOpensBriefOrPullsUp` (four failures in a row, then none) was test isolation: a fixture's store was never closed while its folder went away, and a registry read raced the removal. The fixture now closes its store before removing the folder, in order (`StatementMountFixture.closeAndTearDown`, awaited at every call site), and `RegistryReader.files` reads a directory gone between check and list as the empty directory it already read an absent one as. `StatementImageIngestTests.test_anImagePastedIntoVisualLanguageLandsInItsOwnWell` (one failure) is undetermined and stays on watch.

**Dropped on merit**, each with its reason:

- **A replay can re-arm the `Document`'s one-shot undo-coherent flag over a foreign plain write** (Task 5 N2), leaving a stale redo entry. It needs ⌘Z and a foreign write to the same statement in one main-actor pass, then ⇧⌘Z twice; the fix is in the manuscript's own undo flag (it must vouch for a specific `displayText`), the seam where five rounds each made a new defect.
- **A plain write drops the holding editor's earlier verbs** (a verb in X's editor, then another on X from elsewhere, and the first's ⌘Z is gone). ADR 0023 D1 on the line the manuscript shares; clearing by target there would split the manuscript's figure-birth undo groups. The writer loses a ⌘Z, never text.
- **Keys in a figure-grid cell, the canvas's editor or a scrap** send a statement verb to the window's manager, unreachable from those keys until they move. Identical to shipped for the canvas; delayed, not lost, for the grid.
- **A peer's arrival clears an open statement pane's undo stack**, a pure append included: the safe direction.
- **The reading view's edge cases** (emphasis around a link draws its `*`; a `~~~` block with a blank line splits): display only.
- **A peer op landing while a pane loads is missed until the next arrival**: the manuscript's own window; the next arrival heals it.
- **A keystroke during the mint's flush can duplicate the draft**: never a loss.
- **Task 1's refresh minors.** (A region titled "Cards" was fixed when regions became fold rows, above.)

## Not yet built

Plans 4 and 5 of the same milestone. Nothing above depends on them.

- **Status views** and an edition's own faces; the edition scope in To resolve; the translation surfaces that replace the two interim homes (the translation round report's "Make it a rule" filing line still hard-codes its Brief).
- **Round letters per piece.**
- **The margin setting** and the amendment to [ADR 0027](0027-the-compiler-and-the-editor-boundary.md) §1, which cites this ADR for the marks.
- **The guide, the welcome tour and Claude's help text.** They still describe the old panes and ⌘⌥ keys; the branch does not ship before they are rewritten.
- **A collection script's grouped Scenes fold.** Not built (owner saw this and did not object).

## Consequences

- One question, three positions: what is this held to (Brief), what waits (To resolve), what did I pull up (Pulled up).
- A piece's material is where the piece is, in the tree. A writer can pull a note up beside any chapter and keep it there while changing chapters.
- Brief and the marks are the first place a check's reading of the intent is shown, under four terms a reviewer can check at any commit.
- The statement host is now the load-bearing seam for three surfaces (Brief, the cover, the pulled-up statement); its gate, its close and its foreign re-read are tested as orderings.
- Known limits: the narrower permissions above; opening an intent or History in the centre clears the chapter's typing undo; the interim desk and review pane carry old wording ("ruled" sentences) until plan 4.

## Decisions made during the build

Rulings taken on the build ledger's authority unless marked as the owner's. Cost-if-wrong is cheap in each unless it says otherwise.

1. **Owner, 2026-11-18** ("yes that sounds good"): the desk and the translation review pane show in To resolve until plan 4; Publishing… stays in a piece's row menu after plan 4; the ⌘⌥ map above; a canvas card pulled up is read-only with Open in Centre. He also saw and did not object to Going for's two faces, only solid marks jumping, the centre's details showing with nothing pulled up, "Whose piece this is" moving to To resolve's head, and a collection script's grouped Scenes fold not being built.
2. **Owner, 2026-11-16:** the marks are within must-not #2 (terms above).
3. Quote matching keeps the wider fold (curly to straight, whitespace collapsed, case folded) though the ingest only trims, because the stricter rule drops real marks.
4. The fallback-line index refreshes on a statement change, not only a manifest change (`statementTextRevision`).
5. The Core dated-ruling change stands (above).
6. A foreign arrival on an open statement is fixed in this plan, not left: Brief keeps an intent open, so the plan widened the exposure of a words-losing defect.
7. The cover takes the keys and the hidden-keys class is closed by one question and a census, not three instances.
8. The cover's arrival clears the window's undo stack (above; cost for the owner).
9. A statement verb registers on the first responder's own manager (above); the fourth and fifth rounds went to a fresh implementer with a mandate to simplify.
10. A double-click on the open piece's own row, and an annotation jump with no paragraph, close the cover.
11. The filed line is a link whenever it names a Brief (above); "Already in" for a lesson already standing; "Whole piece" in a collection; the nil-item mark's own line.
12. Open in Centre moves every pulled-up kind (above).
13. A short story's one document keeps its fold.
14. A Collection loose piece's format label becomes a caption at the head of its Brief.
15. The tree's Inbox refresh, which the picker's `.task` did, moved to `RightColumn.pane` (pinned in `WiringCensusTests`).
16. `revealResearchColumn` is renamed `revealPulledUp`, not removed: Open on an item already pulled up changes no subject, so the observer never fires.
17. Plan 2's parked minors: ADR 0036's "outlines" reads "draws selected"; the three register claims that said "the pane" say To resolve.
18. **A region in the fold and pulled up** (owner's ask, 2026-11-20), built with these choices for the owner to overrule: a region row counts as one entry toward the six and sits in the Cards group; a palette card inside a region still lists under Palette; the region's row shows a bare count; a promoted region shows its note first, beside; the fold's region holds what the shelf pins while the region beside holds what the canvas shows.

## Hand checks owed to the owner

Plans 1 and 2's hand checks stand; this plan adds:

1. ⌘2 on a chapter: the line, Going for, Decided, then From the book and What Claude has read. Type a line; it shows on the card, in the outline and above the prose. Clear it; the intent's opening shows instead.
2. Run a check, then ⌘2: sentences the draft strains against are underlined solid, silent ones dotted. Click a solid one: To resolve opens on that finding. Edit the intent: the marks go until the next check.
3. Answer a finding in To resolve: it says "Filed under this chapter's intent" and the answer is under Decided. Keep a letter's habit as a lesson, Add to intent, Make it a rule on a round report, and Confirm something Claude has read: each says where it filed, and a lesson already standing says "Already in".
4. ⌘2 on the Book (every decision, filterable; open What I've Learned, First Reader and Visual Language from it), on a Part and on an edition.
5. Open the intent in the centre from Brief; write at length; close it. With the canvas open, click a chapter and edit its intent and line in Brief without opening the chapter.
6. A chapter's fold: research, cards, palette cards, figures and links in both directions; past six, groups with counts. In a novel the research is marked as linked; in a collection it is the piece's own. Say if a short story's one row should have no chevron.
7. Click a research note in the fold: it is pulled up beside the chapter and editable; with Lock on, it is not. Click a card: it is read-only with Open in Centre. Change chapters: it stays until closed. Narrow the column to its minimum with a long-titled note: the control still fits.
8. The word target is on the status line under the text; tags are a column in Outline and in the row menu; links and Publishing… are in that menu, and in a screenplay's script row.
9. Try each ⌘⌥ key against the table above.
10. **Undo (focus at the click is unmeasurable from source, so by hand, also with keyboard navigation on):** in an intent's editor type, click Revoke; the caret stays and Edit ▸ Undo reads "Undo Revoke Ruling"; type a character, ⌘Z ⌘Z ⌘Z is the character, then the Revoke, then greyed. Two Revokes then ⌘Z ⌘Z ⇧⌘Z ⇧⌘Z. Type in a chapter, Revoke in Decided, ⌘Z once undoes only the Revoke. Revoke in Brief with the keys in another intent's editor, then ⌘Z.
11. **To confirm:** the narrower permission for tags, targets, links and Publishing…; the Core change that can mark a translation stale once; opening an intent or History in the centre clearing the chapter's typing undo.
12. The three final-wave rulings, built: the View menu's titles say what the keys do (To Resolve, Brief, Pull Up …, Open the Piece's Fold); ⌘⌥H on the Book pulls up the project's History; ⌘⌥L from Brief shows To resolve with the one-line explanation, and it goes when you move on.
13. **History of a chapter pulled up, then another chapter opened:** the pulled-up History offers no Rewind; open its chapter again and Rewind returns and rewinds that chapter only.
14. **Brief's line at ⌘Q:** type a line, do not press Return or click away, ⌘Q, relaunch: the line is there.
15. **Tags…:** type a tag and press Return: the tag lands and the sheet stays. **Target popover:** type a number, press Esc: nothing is written.
16. **⌘⌥E** on a chapter inside a closed Part: the Part opens and the fold shows.
17. **A region in the fold:** bind a region to a chapter on the canvas. The chapter's fold shows the region as one row with a count; its chevron opens its cards top to bottom. Click the row: the region is pulled up, its scraps in full, its pictures at column width, its notes as titles (click one: it replaces the region). Type in one of its scraps on the canvas: the words beside follow. Open in Centre: the canvas opens with the region selected. Delete the region on the canvas: the column says it is gone, with Close.
18. Smoke: launch, New project, Novel, "Smoke", type a sentence, ⌘Q, relaunch, open from Recents, sentence intact.
