# ADR 0037 — Brief, the pulled-up thing and the fold: what the right column is about, and what hangs under a piece

**Date:** 2026-11-20 · **Status:** Accepted (plan 3 of a multi-plan milestone; see "Not yet built") · **Milestone:** shell-p3-brief-and-the-pulled-up-thing (branch `claude/shell-without-personas`) · **Design:** `docs/superpowers/specs/2026-11-16-subject-resolve-brief-shell-design.md` ("Brief", "The pulled-up thing", "The fold") · **Builds on:** [ADR 0035](0035-the-subject-not-the-persona.md), [ADR 0036](0036-to-resolve.md) · **Cited by:** the amendment to [ADR 0027](0027-the-compiler-and-the-editor-boundary.md) §1 (plan 5)

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
| Pulled up | something is pulled up (`subject.beside`) | that item with its details, under `BesideHeader` (Open in Centre, Close) |
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
- **Linked and owned look different.** A Collection piece's fold holds research in the piece's own folder, drawn as the Research section draws it. A novel chapter's fold holds links to shared research, quieter, with a trailing link glyph, flat and never renamed there.
- **A row acts by one rule.** Research and figures are `List` tags that take the centre as anywhere in the tree; a card or palette pin is pulled up beside by a `Button(.plain)` (tripwire 9) and a second click puts it away; a link travels to its piece; a double-click or Open in Centre always opens in the centre. The chevron shows only when the piece has entries.
- **A single-document project keeps its fold** (a short story's one document: chevron and grouped counts), because the fold is where a piece's material lives in every project type. Cost: one chevron on a single row; one line to remove.
- ⌘⌥E opens the faces' piece's fold in the tree and scrolls it into view.

### The pulled-up thing

One thing at a time is pulled up beside the centre (`PulledUp`, `WindowSubject.beside`, widened from a research item): a research item (note, table, PDF, palette card), a figure, a canvas card (a scrap or a picture), What I've Learned, First Reader, Visual Language, or a piece's History. It persists across subject changes until closed (Close, or Esc through `WindowEscapeArbiter`, ahead of the centre item's cover; `PulledUpEscape`). Pulling a second thing up replaces the first.

- **Open in Centre MOVES it.** The pulled-up position empties, for every kind: a research note, a figure, a card, a statement, History. Closing the centre item does not pull it back up; to read an intent beside the text again the writer pulls it up again. (The first reading kept a placeholder behind; one rule for every kind is cheaper to carry.) A statement or History opens in the centre as a cover (below), over the piece it names, or the Book.
- **Never a second editor on what the centre shows** (`PulledUpView.centreShows`, the one spelling). Where the centre already shows the item, the pulled-up view draws the read-only form or the "open in the centre" line. A card on the palette wall is never edited beside it too, and the pulled-up editor and the wall's editor settle a card's pending edit before the other seeds (`EditorHandOverTests`).
- **Editable beside:** a research note and a palette card (the note is a second editor, `isSecondEditorInItsWindow`), a table's grid, a statement. **Read-only beside:** a canvas card, by the owner's answer, because a card's words live in the canvas's shared text storage, and a second editor beside the manuscript would put them at risk (tripwires 26–28). A scrap beside follows the canvas's own typing; Open in Centre opens the canvas and selects the card; a card that is no longer on the canvas shows a missing state with Close. Lock covers a pulled-up note, card, table and figure exactly as in the centre; a statement asks its own posture.
- **Hidden when it would show nothing** (above). With nothing pulled up, the position shows the centre's own details, so the canvas's selected card or region is not lost with the old Inspector.
- **It is never what the tree selects or the canvas lights** for a statement or History (neither is a tree row); a pulled-up research item or figure is the tree's `beside` outline as before.
- **A stored subject reads back across the change.** `PulledUp` keeps `BinderSubject`'s `{"kind","id"}` shape for the two kinds they share, so a `beside` written by plans 1–2 reopens; the kinds that are not tree rows are stored under a new key a previous build ignores; an unknown kind reads as nothing beside (tripwire 11). `UIState` no longer reads the old `detailSegment` key at all.

### The centre item and the keys

A piece's intent, a Book statement or a piece's History can be opened in the centre as a **cover** over the manuscript editor (`CentreItem`, `CentreItemCover`). `EditorHost` stays mounted under every cover (tripwire 6), so the cover owns the keys, or the manuscript would take keystrokes the writer cannot see.

- **While the editor is covered, the manuscript's text view is never first responder** (`CentreKeys`). The cover claims the keys for its own editor on arrival and on each item change; whatever re-asserts the manuscript (a load, a find, a navigation) is moved off; a closing cover hands back only the keys it held. A view inside the manuscript (a figure-grid cell editor, a review composer, the find bar's Replace) counts as the manuscript, found by ancestry.
- **A place closes the cover first.** `ManuscriptNavigation.go` closes the centre item before any place lands; an annotation jump with no paragraph and a double-click on the open piece's own row close it too.
- **One question: is the manuscript the editor the writer can see?** (`ProjectWindow.manuscriptIsVisible(route:)`, reached by an editor through `CentreKeys.manuscriptIsVisible(holding:)`). Every manuscript-writing entry point that does not go through the text view's own keys asks it: the Insert commands and Format ▸ Table through `manuscriptCommandContext`. `EditorWriteCommandCensusTests` classifies each editor observer as a writer or not by name, with a planted offender, so a new one cannot be added unasked. Only the centre item's cover had the hole; every other cover stands where `EditorHost` has no document or is unmounted.
- **Esc does not close the cover while the keys are in its statement editor** (the arbiter's text-editing rule): the Close button is the way out.
- **Every new statement host asks `statementIsInTheCentre`** before mounting, so the placeholder is decided before the mount, never discovered by a refusal.

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
| ⌘⌥H | pull up the faces' piece's History |
| ⌘⌥E | open the faces' piece's fold in the tree |
| ⌘⌥L, ⌘⌥K | To resolve (where translation review and the desk show) |

`RightColumnMountingTests.test_eachOldPaneKeyLandsWhereTheMapSays` and `test_everyPositionAndPullUpHasAMenuShortcut` pin the map.

### Interim homes

Until plan 4 builds an edition's faces and the piece-in-a-language view, the Department desk shows in To resolve while an edition is the faces, and the translation review pane shows there while translation review is on: today's views, mounted unchanged in the position the design gives their successors (owner's answer, 2026-11-18). Without them publishing and translation review would have no home.

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

The target field is a String that commits what was typed on Set, Return and focus loss: a numeric field commits only on Return or focus loss, so Set alone would have written the pre-edit value. The status line measures the piece **open** in the centre, not the faces' piece (it took the target from the faces before, so a Book on the faces over an open chapter showed the editor's count against no target).

### The permission change

**Tags, targets, links and publishing now ask restructure permission** (`TreeStructureVerbs.mayRestructure`; a screenplay's project-level page target asks the project stream's `.restructure`). They are manifest or structure writes, and the line beside them already asks it. The Inspector asked nothing for them, so a reviewer or translator who could set them there cannot now: they are hidden, never disabled. For Publishing this narrows who may change a piece's publish settings to the book's author or the piece's own author. **This stands as built and awaits the owner's confirmation.** A Collection's loose pieces gain Tags… and Add Link… (the old pane never offered them there).

### A Core change that directs retranslation

`RulingsSection.parseItem` now reads a comma-less `— ruled <date>` as dated with no provenance, the form `lineText` writes for exactly that ruling, so it must read back dated. A dated ruling IS dated, and directing retranslation is what a dated ruling does: `BriefingDoctrine.isDirected` now honours it (`BriefingDoctrineTests.test_aDatedDirectiveWithNoProvenanceDirects`). **Cost:** an existing project with such rulings may see a translation marked stale once. Core changed, so core and phone gates ran.

## Gone by design

- The pane picker and `DetailSegment`, with `DetailPaneToggle`, `postDetailSegment` and `UIState.detailSegment`.
- The Inspector (`InspectorView`, `PieceInspector`, `IntentAffordanceRow`, `InspectorLinksSection`): each field has a home above.
- The Intent, Visual Language, What I've Learned and First Reader panes as picker members: they are Brief's Going for and the long statements pulled up or opened in the centre. The "Open Intent" row is gone because Brief shows the intent itself.
- The References pane and its empty state naming two ways to pin: the shelf is a piece's fold, and an empty fold has no chevron.
- The study column (`AssistantColumn`): one pin, read-only, ended by any newer act. The pulled-up thing persists until closed, and a research note or palette card is editable there.
- The History, Translation and Department panes as pickers: History is pulled up, the other two are To resolve's interim answers.
- A selected group showing the project's intent: it shows the Part's Brief.
- The Inspector's debounced draft (it saved every field together 500 ms after any edit): each home writes once, on its own commit.
- The retired picker, study-column, References and Inspector suites: each assertion that policed behaviour that still ships moved onto the live code (the mapping is in the task report), and the presentation rule is `RightColumnMountingTests.test_escapeClosesThePulledUpThing`.

## Parked

Each was adjudicated after the undo work's last allowed round, as real but not load-bearing; the whole-branch review's final wave triages them.

- **A replay can re-arm the `Document`'s one-shot undo-coherent flag over a foreign plain write** landing in the same apply pass, leaving a stale redo entry (misplaced text, or the stale-range crash class). Very low reach; the flag's mechanism predates the plan and statement `Document`s' exposure to it is new. The fix is `Document`-wide (the flag must vouch for a specific `displayText`).
- **A plain write drops the holding editor's earlier verbs** (a verb in X's editor, then another on X from elsewhere, and the first's ⌘Z is gone). That is ADR 0023 D1 on the line the manuscript shares; clearing by target there would split the manuscript's figure-birth undo groups. A narrow loss against what shipped.
- **Keys in a figure-grid cell, the canvas's editor or a scrap** (each with its own undo stack) send a statement verb to the window's manager, so it is unreachable from those keys until they move. Identical to shipped for the canvas; minor for the grid.
- **The verb-undo tests draw undo event boundaries with the private selector `_endTopLevelGroupings`** (`StatementVerbUndoTests`). Three tests go red, with no crash, if a future macOS removes it. Swap for `groupsByEvent = false` and explicit groups.
- Also noted, not built: a peer's arrival clears an open statement pane's undo stack, a pure append included; an open statement document does not re-read on a registry change or admission (only `openDocuments` does); `ProjectStore+CollectionPieces.swift` closes a host's live statement document on a failed promotion and leaves the host mounted over the closed `Document`, so each keystroke is dropped without a placeholder (pre-existing, Important); two statement-area tests failed once each and passed on rerun (`StatementImageIngestTests.test_anImagePastedIntoVisualLanguageLandsInItsOwnWell`, `test_aStatementMarkOpensBriefOrPullsUp`, a file read while `.maugham/people/events` was written) and the whole-branch review traces them.

## Not yet built

Plans 4 and 5 of the same milestone. Nothing above depends on them.

- **Status views** and an edition's own faces; the edition scope in To resolve; the translation surfaces that replace the two interim homes (the translation round report's "Make it a rule" filing line still hard-codes its Brief).
- **Round letters per piece.**
- **The margin setting** and the amendment to [ADR 0027](0027-the-compiler-and-the-editor-boundary.md) §1, which cites this ADR for the marks.
- **The guide, the welcome tour and Claude's help text.** They still describe the old panes and ⌘⌥ keys; the branch does not ship before they are rewritten.
- **A collection script's grouped Scenes fold.** Not built (owner saw this and did not object).
- **Three rulings of the final wave, not built at this commit:**
  - The View menu's titles still say Inspector, Intent, History, References, Translation and Department. They are to be renamed to what the keys now do (To Resolve, Brief, "Pull Up What I've Learned / First Reader / Visual Language / History", "Open the Piece's Fold", the filter-opening items named for their filter), with the doc-sync test in step. A menu naming things that no longer exist is wrong; today it is wrong.
  - ⌘⌥H with the Book, or no piece, on the faces is inert today. The ruling is that it pulls up the **project's** History (the checkpoints, as the old pane showed), so no capability is lost.
  - ⌘⌥L outside translation review shows To resolve and no longer explains how to enter review. The ruling is that To resolve's empty state for that request keeps a one-line explanation.

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
12. The three final-wave rulings above are not built: the View menu's titles, ⌘⌥H on the Book and ⌘⌥L outside review will read as they did until that wave lands.
13. Smoke: launch, New project, Novel, "Smoke", type a sentence, ⌘Q, relaunch, open from Recents, sentence intact.
