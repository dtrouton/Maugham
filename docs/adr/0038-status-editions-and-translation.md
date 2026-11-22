# ADR 0038 — Status, editions and translation: the window answers "what needs me?" at every altitude, and the desk goes

**Date:** 2026-11-22 · **Status:** Accepted (plan 4 of a five-plan milestone; see "Not yet built") · **Milestone:** shell-p4-status-editions-translation (branch `claude/shell-without-personas`) · **Design:** `docs/superpowers/specs/2026-11-16-subject-resolve-brief-shell-design.md` ("The tree", "The centre, by subject", "To resolve", "The toolbar", "Translation", "Where today's surfaces go") · **Plan:** `docs/superpowers/plans/2026-11-21-shell-p4-status-editions-translation.md` · **Builds on:** [ADR 0035](0035-the-subject-not-the-persona.md), [ADR 0036](0036-to-resolve.md), [ADR 0037](0037-brief-and-the-pulled-up-thing.md)

## Context

After [ADR 0037](0037-brief-and-the-pulled-up-thing.md) the right column had its three positions, but two of plan 3's interim homes still stood in To resolve's place: the Department desk (while an edition was the faces) and the translation review pane (while translation review was on). While either showed, To resolve's own list was unreachable and ⌘⌥A/D/T dropped their filter (0037's "interim loss"). The Book's Status was a passes board that said nothing about notes or to-dos; an edition had no centre of its own (every edition showed the same book); the tree said nothing about which rows waited on the writer; a whole-book translation run aged out every chapter's letter but the newest ten; and a failed promotion of a Collection piece left the Collection window with a closed `DocumentStore`.

This ADR records what plan 4 built, as built at `a83e1502`. Each section gives the decision, why, what it cost, and what would overrule it. Rulings the build ledger (`.superpowers/sdd/2026-11-21-shell-p4/progress.md`) made on the owner's behalf are listed together below, each marked answered or not.

## Decision

### 1. Round letters per piece, and one queue per project for the rounds ledger

**Decision.** A translation round's letter is kept per piece beside the per-language ring, not instead of it: `TranslationRoundStore.Ledger.latestByPiece` in `.maugham/translations/rounds/<lang>.json` holds each piece's latest *finished* round, keyed by doc id (`latestFinished(language:docId:)`, `latestFinishedByPiece(language:)`, `pieceRounds`, `trendsByPiece(language:)`, one ledger read per language, never per row). **Finished means ended and not cancelled**: a failed round's partial letter counts, a cancelled one does not (`TranslationRoundStore.isFinished`). An editor's round keeps its letter per pass the same way: the per-device diagnostics sidecar gains `latestRoundByPass`, written only when a round is superseded (`DiagnosticsStore.latestRounds(docId:)`). A ledger written before the map exists reads with an empty map and falls back to the ring's finished rounds (higher number wins).

Every read-modify-write of the ledger runs on **one serial queue per project** (`TranslationRoundStore.queue(for:)`; `mutateInOrder`, `recordInOrder`, `appendInOrder`); `changingOnQueue` is the only load-then-write, the raw `load` and `write` are private, and the file is replaced atomically (`TranslationRoundStoreTests.test_theLedgerIsReadAndWrittenThroughTheQueueOnly`). The verbs in To resolve rewrite the stored record, never the row's copy, and post `.maughamTranslationRoundChanged`.

**Why.** The ring is per language: a twelve-chapter run aged two chapters' letters out of it, so a chapter's head could not show its own latest letter. The queue exists because the controller found, in source, that verbs moved off the main actor raced each other and the pipeline's append, and a lost write was a lost decision.

**Cost.** Two derived JSON files gain optional keys (no op-log or schema change). An older build that rewrites the ledger drops `latestByPiece` (and the rounds' new `ruled` and `translatorName` fields) until the newer build's next round. Synchronous main-actor reads (`nextNumber`, MCP's status) wait behind queued writes; a peer Mac's write is outside the queue and arrives with no event (Known limits).

**Overrule if** letters must survive any build on any device: they would then belong in a synced, schema-versioned store.

### 2. The Book's Status and the edition's Status

**Decision.** Status is a view of the centre, chosen in the toolbar (section 13). **The Book's Status** (`ReviewBoardPane`) widens the passes board to stage, each pass, open notes and open to-dos per chapter; a to-do count opens the chapter on Mine; a footer row "The Book — N to-dos" opens the Book's own; a Part heading opens the Part; the arrows and Return move and open (`ReviewBoardKeys`); returning to Status scrolls to and marks the piece last opened. The to-do counts come from the presence read's Book snapshot (`BinderTreeSectionsState.openToDos`), not a third walk, so they are as live as the tree's dots.

**The edition's Status** (`EditionStatusHost`, `EditionStatusView`, `EditionStatusRows`) lays out, per chapter: translated counts, the latest round, open questions, changes to look at, the trend and the publishing settings. The Source edition's Status shows the publishing column only. Its questions come from the presence read (`BinderTreeSectionsState.bookReading`), not a load per chapter. `EditionStatusRows.isToLookAt` is THE predicate for a change that waits, read by the Status, the list and the dot. A row's click opens the chapter read in the edition's language (owner, 2026-11-21).

**Why.** "What needs me?" must be answerable at the Book's altitude without opening each chapter. One predicate keeps Status, list and dot from disagreeing.

**Cost.** Measured at 200 chapters (`EditionStatusCostTests`): a Status read went from 1,649 to 861 ms wall time, longest main-actor step 7.7 ms. The cells are terse at 480 pt ("TOC · R", symbol headers); the sentences are in each cell's help and VoiceOver label.

**Overrule if** the owner wants Source's Status richer, or the to-do counts read from their own walk.

### 3. The edition's centre and its page jump

**Decision.** An edition is a subject with two faces of its own, Book and Status (`EditionView`, `UIState.editionView`). Its Book is the compiled book in its own language: `PublishPreviewResolver.edition(_:language:sourceLanguage:)` filters the publications (a bilingual book's `LanguageSet.identity`, such as `en+sr`, is split on `+`), applied through `PublishCentreModel.preview(for:)`. Compile… and the imprint picker sit in the book's header (`EditionCompileBar`); an edition with no book gets the bar over its notice (`EditionNoticeCover`). A failed or refused compile that left problems covers the centre with them (`coversWithProblems`); a book that landed with warnings only offers Show Problems. The running-compile pill is hidden only while this window's own runner runs.

**The page jump.** A chapter clicked in the tree while an edition's book is the centre scrolls the book to where that chapter starts (`PDFPreview.Target(page:ask:)`). The page is found by `PDFAnchors.locate`, which trusts only an anchor the piece does not share with another piece, corroborated by the next one; it answers `.page`, `.ambiguous`, `.notInBook` or `.noAnchors`, and the header says "X starts on page N", says the chapter is outside the imprint, or says "Compile again to jump to chapters" for a book compiled before the anchors existed.

**Why unshared, corroborated anchors.** The emission contract names a paragraph's anchor `p-<tag>-<¶id>` with no document in it, and a `¶id` is unique only within its document, so two chapters can share an anchor name and the book keeps one of them. "The first name that resolves" would land on another chapter's page. The emission is not changed here; the defect is filed as a register claim (`M7-PB-012`) with the tests that pin the workaround.

**Cost.** A chapter whose anchors are all shared, or disagree, says it cannot be placed rather than jumping. A click on the tree row already selected does not jump again (the `List` delivers no write); the header's link is the way back.

**Overrule if** the emission contract adds the document to the anchor name: the reader then needs no corroboration, and every book needs recompiling.

### 4. The edition's To resolve, and its item kinds

**Decision.** With an edition as the faces, To resolve is that edition's list (`ResolveScope.edition(language:isSource:docIds:)`, `ResolveEditionItems`). Four item kinds join notes, findings and to-dos: a translator's **change** (`ResolveItem.translationChange`), a **glossary proposal**, a **design proposal** and a **compile problem**, under three new sources (`.changes`, `.design`, `.compile`). Translator's questions are listed in the edition's language, grouped by chapter. The head (`ResolveHeadShape.edition`, `EditionHeadView`) carries the translator's latest letter and **Run Whole Book**, with a line saying what it runs and roughly what it costs ("Runs every chapter of the book: N chapters", or the chosen imprint's count and name; the budget from `TranslationPreflight.editionBudget`, idle only, off the main actor, cached). When the newest round failed or was cancelled, the head says so in the round's words above the last finished letter. The Source edition's head carries the designer's line and Run design with a direction (owner, 2026-11-21).

The rules, as built:

- **A design proposal is listed in every edition** (its gate covers any edition's centre and every edition's pages use the design). Approve and Discard check the stored status, not the row's copy (`refusalUnlessStillPending`); Discard asks first; a reviewer is not offered them (`DesignGate.mayDecide`).
- **Only a compile problem that stopped a book is listed and marks the editions**; warnings stay behind Show Problems (controller's ruling).
- **Filing settles a change**: Keep mine and Make it a rule set `ruled` with `dismissed`, so the change leaves the list like Fine; the report says "Ruled." (controller's ruling).
- **Identical glossary proposals in one round are one** (`GlossaryProposalRecord.deduped`); a verb claims its row before its first await and re-checks after it.
- The list says "Still reading the book's questions…" until the presence read is complete (`BookReading.isComplete`); it never says settled early.
- A question's click opens its paragraph read in the edition's language.

**Why.** The desk was a second answer to "what waits on me in this edition"; To resolve is the one list (0036), and the edition's dot, its Status and the empty line all read one predicate.

**Cost.** Every edition shows the design proposal. A change the writer filed leaves the list (it stays in the report).

**Overrule if** the owner wants filed changes kept visible, or warnings listed.

### 5. The desk is deleted, and where each capability went

**Decision.** `DepartmentPane` and `DepartmentPaneHost` are deleted. Their values were renamed for what they are (`TranslationRunState`, `DesignRoundState`, `CompileRunState`, `CompileSheet`, `CompileRunner`, `EditionCastSheet`), and the statics moved, not deleted. `TreeEditionRowsTests.test_everyDeskCapabilityHasAHome` lists every desk capability with a code token in its new home (42 homes, 4 gone with reasons). The homes:

| Desk capability | Home |
|---|---|
| Add Language… | the Editions header's `+` (drawn in every book, `TreeEditionRows.drawsSection`), the Source row's menu, File ▸ Add Language…; `EditionWiring` presents one `EditionCastSheet`, `EditionCastVerbs.addLanguage` acts, the new edition is selected; adding one the book has selects it |
| Rename the translator, reader, collator | the edition's Brief, Cast ▸ Change… |
| Rename the designer | the Source edition's Brief, Designer ▸ Change… |
| The edition brief and its proposal | the edition's Brief (`StatementPane`'s gate); a proposal for a language with no edition shows on the Source's Brief with Add <Language>… and Discard (which asks first); an edition with a proposal reads "Proposed" in the tree |
| Run Whole Book, Cancel, Show | the edition's To resolve head |
| Run design, Request Changes, Cancel, Show | the Source edition's To resolve head |
| Compile…, Cancel, Show Problems, the imprint picker | the edition's compile bar |
| Run one chapter | the head of a piece read in a language (section 7) |
| "7 legs · ~N words" per language | gone (it opened every chapter per read); the cost is on Run Whole Book's line |

⌘⌥L is **To Resolve: Questions**, wherever the faces are; ⌘⌥K is **To Resolve: <Language> Edition**, the edition the window reads in, else the Source's, disabled in a book with no editions (`EditionWiring.editionForTheKey`). A round records the translator's name it ran under (`TranslationRound.translatorName`), so a rename applies from the next round and an earlier letter keeps its name.

**Why.** Each capability now lives where the writer is when they need it, and To resolve's list is reachable on every subject: the interim loss of 0037 is closed.

**Cost.** One `+` menu with one item; the per-language cost figure before a press is replaced by one line.

**Overrule if** a capability turns out to be missed: the census names where each went.

### 6. Reading a piece in a language

**Decision.** A piece with translations can be read in a language from the toolbar's language switch (absent on a piece with none; a warning when the translations folder cannot be read), View ▸ Read In ▸ …, and ⌃⌘L (Read In Next Language). `ReadingLanguage` decides what language a subject is read in (`of(subject:switched:sourceLanguage:)`, `carried(_:toPieceWith:)`, `next(after:in:)`); `ReadingLanguageModel` holds the per-project choice and **Show Source Under Translation** (on by default, remembered per project). The surface is the translation, read-only, with the source under each paragraph in grey (`TranslationBadgeLayout`); a stale paragraph is amber-dotted with amber-tinted ink and its current source under it; an untranslated one shows its source once, lighter, with a hollow dot. A quiet line over the text names the language, the counts, and Read Source.

- **The membrane follows the buffer.** `EditorCoordinator.bufferHoldsTranslation` is set before the translated swap, or at mount (`EditorSurface.mount(_:on:servesTranslation:control:)`), and cleared only when the source has landed (`sourceLanded`); while it holds, the text view is not editable and every write route refuses: typing, paste, drop and drag-move, spelling, input methods, Services, Writing Tools, Find's Replace, a sync merge (`ReadingTranslationWriteRouteTests`, one test per route). Find reads Source first; in review mode the toolbar offers only Translator's note and no note highlights fall on the translation. Copy takes the translation; a selection inside a grey line copies its source.
- **Undo is barred while reading.** A throwaway undo manager serves the reading surface; `ReadingUndoGuard` disables Undo and Redo window-wide; on the way back the window's stack is kept when the source did not change, and only text-storage typing is dropped when it did (op-level undo is kept). So type → read in Serbian → back → ⌘Z undoes the typing.
- **Coordinates map both ways** through the coordinator (`surfaceLocation(forSource:)`, `sourceLocation(forSurface:)`, over the badges the buffer holds), so a go-to-paragraph, a find match and a scene land on the right paragraph with source lines interleaved; the reading position is kept by visible paragraph across a switch.
- **The language is carried** to the next chapter when it has that translation, else Source (owner, 2026-11-21); a chapter opened from an edition's Status opens in that edition's language.
- **Refresh**: a source edit refreshes a reading window off the main actor after a 400 ms pause (`TranslatedSurfaceRefresh`; measured 346.6 → 19.9 ms of main-actor work per typing pause), with scroll and selection kept.

**Why.** The design's "read in a language" replaces translation review as a mode: it is a way of reading a piece, not a different window. The membrane is keyed to what the buffer holds, not to the control's state, because the window between a control change and the source landing is exactly where a keystroke would write a translation into the manuscript.

**Cost.** **While a translation is read, no undo is reachable in that window**, including undoing a note resolved in the right column, until back in Source. Reading position, not a caret, shows over the translation.

**Overrule if** the owner wants Undo of non-text acts while reading: the guard would have to tell a text undo from a note undo.

### 7. To resolve for a piece read in a language

**Decision.** A piece read in a language (switched, or faced under its edition) is its own To resolve scope (`ResolveScope.pieceInLanguage`, `ResolvePieceInLanguage`): that language's questions and that chapter's round changes and glossary proposals, grouped by paragraph (a glossary term under "Whole chapter"), headed by "<Language> translation" and **that chapter's own latest letter** (`TranslationRoundStore.pieceRounds`). **Earlier letters** (`ResolveHead.earlierLetters`) is a menu at a piece's head, hidden with one letter, and reaches an editor's earlier round ("Perkins · round 2"). The head's **Run** runs this chapter into the language with its cost; `pieceRun(status:queued:docId:language:)` decides whether the pipeline's run is this chapter's (Cancel), queued for it in a whole-book run (Cancel), or another chapter's (a line naming it, no Cancel, no Run). The caret's paragraph gets "This paragraph" with its chip, Gloss and Ask the Collator (`PieceInLanguageCaretSection`; an answer belongs to the paragraph it was asked about).

**Head lines, not list items.** "N paragraphs out of date · M not translated yet" opens to links that land on each paragraph in the language; left-over translations of deleted paragraphs are shown with their text and **Clear**, which asks first and clears exactly what was shown or refuses (`clearDecision(shown:now:)`); `ResolvePieceInLanguage.clear` writes tombstones through the one sanctioned second `appendBatch`. They are not items because the list is exactly what marks a row: a stale paragraph is settled by a run, a left-over by a Clear, never by a decision, and listing them would dot every chapter with a stale paragraph.

Off the open piece (an edition faced, a chapter clicked) the rows read and do not act; the head says "Open this chapter to answer its questions" (or "…to run a round on it"), and "Opening…" while it loads (`openSlot(isOpen:isOpening:hasItemsToAnswer:noun:)`). The translation review pane (`TranslationReviewPane`, its modifier and indicator) is deleted; `ResolvePieceInLanguageTests.test_everyReviewPaneCapabilityHasAHome` lists 37 homes and 4 gone.

**Why.** One list per subject (0036): a piece in a language is a subject, so its raised items are a To resolve, not a pane.

**Cost.** A stale paragraph is visible only as a count and a link, not inline in its group. A change made only in Spanish dots the Spanish edition's row, not the chapter's.

**Overrule if** stale or left-over paragraphs should wait on the writer: a new item kind, and a translation derive per piece in the presence read.

### 8. The tree's marks

**Decision.** A row with anything To resolve would list carries one accent dot, 5 pt, at its trailing edge (white on a selected row), never a number (`ResolvePresence.rowMark`, `ResolvePresenceDot`); a Part and the Book roll up what is inside them; in a screenplay, the scene an item falls in. A piece that would not read, with nothing listed, draws a **hollow ring** labelled "Could not be read" (RULING-54). An edition row is dotted by its own list (`Marks.editions`), and an edition with a brief proposal waiting reads **"Proposed"** in a capsule beside it (`Marks.proposedBriefs`). The **Canvas row** carries a red "new" dot, the Inbox's look, after something is dropped on it with the canvas closed, until the canvas is next opened (`marksArrival(open:)`); it is the window's, not persisted. The full contract of the dot is [ADR 0036](0036-to-resolve.md)'s "The tree's dot".

**Why.** "What needs me?" at a glance, from the tree, with nothing open.

**Cost.** One glyph per marked row (a title loses about 11 pt); the accent shares its colour with To resolve's unread dot.

**Overrule if** the owner prefers the grey beside the stage dot that the plan named.

### 9. The presence walk is off the main actor

**Decision.** The read is mounted on the window (`ResolvePresenceWatch`), never on the tree. Closed pieces are read off the main actor eight at a time (`ResolveChunkedWalk`), each chunk folded in as one main-actor step; a change mid-walk is neither lost nor counted twice; a walk skips a held piece whose fingerprint is unchanged, so a steady cadence of events still reaches the end; the open pieces are read off their `Document`s. Measured at 200 closed chapters (`ResolvePresenceCostTests`): opening or closing a chapter 825 → 1 ms; the first read when a window opens went from one 680 ms main-actor step to about 28 steps whose longest is about 3 ms. The detail is in [ADR 0036](0036-to-resolve.md).

**Why.** The dot made every window pay a whole-book walk at open; before plan 4 only the Book's To resolve did.

**Cost.** Each window walks for itself on one pool thread (about 600 ms at 200 chapters). To resolve's own Book list still walks synchronously, unchanged.

### 10. The promotion door, and one promotion at a time

**Decision.** Promoting a Collection piece to its own project **closes only what it moves**: `DocumentStore.withdrawForPromotion(path:)` closes the piece's `Document` and holds its path with a token, `returnFromPromotion` gives it back, and only the hold that took a path gives it back. **Every manuscript load by path passes one door**, `DocumentStore.loadManuscript(path:title:url:actor:session:presenter:recovery:through:)`, which refuses a held path (`ManuscriptBeingPromoted`) and closes a load a promotion overtook; `TripwireGrepTests.test_everyManuscriptLoadPassesThePromotionDoor` counts every raw `Document.load(` in production (tripwire 59). **One promotion at a time per Collection** (`PromotionAlreadyRunning`, naming the one running). `EditorHost` waits on the hold and loads again on `promotionReturns`, and registers only if the item is still that loose piece at that path. A failure's alert names the folder holding what could not go back, with Reveal in Finder and Copy Path, and names figures sent to the Trash.

**Why.** The old promotion closed the whole store, so a refusal or a success left the Collection window dead; and when the hold first protected `EditorHost` alone, Replace All, the figure relabel, the rename sweep and MCP reads still loaded the held path and wrote to an orphaned op log (the half-rule shape).

**Cost.** A second promotion while one runs is refused, not queued. The promoted piece's centre shows "Loading…" for the promotion's length. The piece's op log does not travel with it (owner's ruling below; its own work).

**Overrule if** two promotions must overlap: the carry plan, figures and Trash would need exercising interleaved.

### 11. Keyboard reach in the fold, and the arrow/settle rule

**Decision.** A fold's pull-up rows (cards, pictures, regions, palette pins, figures, research notes) select through a tree-local tag (`TreeRowTag.pullUp`), not new `BinderSubject` cases. **An arrow selects at once and pulls up only after a ~300 ms settle, and only if the right column is already showing a pulled-up thing**; it never reveals a hidden column or changes the faces. Return or Space pulls up now and shows the column; Return again puts it away. Back history records settled pulls only. ⌘↓ opens the selected row in the centre. **A click is the button's one act**, whatever order the table's own selection arrives in (`TreeSelectionGesture`): a single click on a card not up brings it up and it stays. Link and scene rows stay buttons (they travel). A Collection script's fold leads with its Scenes; a palette card inside a region lists under the region (a card also pinned to the piece stays under Palette, the shelf's first claim).

**Why.** Arrowing through a fold must not churn the right column or fill Back; a click must never pull up and put away in one gesture.

**Cost.** ⌘↓ has no menu item yet. Two open folds listing the same item give two rows one tag.

**Overrule** — answered: the owner hand-checked click, arrows and settle on 2026-11-22 and they "look good".

### 12. Drop feedback and the insertion line

**Decision.** Every drop target in the tree shows what its drop would do, asked of the drop's own rules at the pointer's place (`DropIntent.Position.of(y:height:halves:)`, the one reading for hover and drop): **into** is a dashed, filled ring; **beside** is an insertion line with a hollow dot at its left end, above or below by the row's third (a Part's middle third is into; a Collection piece halves); nothing shows where nothing lands, and the drag springs back. The look is dashed so it is never confused with a standing mark (the open row, the faces, the selection). The line follows the pointer by sampling the mouse against the row's screen frame while targeted (`TreeDropHover`, `TreeRowScreenFrame`). A drop on the **Canvas row** (`TreeCanvasRowDrop.verdict`, cached per manifest stamp and canvas revision) lands a capture, research note, research picture or Finder picture loose through Send to Canvas's route.

**Why.** Every look the writer sees must be the drop that lands (owner's answer 4, 2026-11-21).

**Cost.** Where the line cannot be verified during a drag the row falls back to the neutral ring. One undo step per dropped file.

**Overrule** — answered: the owner hand-checked the insertion line on 2026-11-22 ("looks good").

### 13. The toolbar

**Decision.** Four items join Lock: the centre's **view switch** (Cards / Outline / Status on the Book, Book / Status on an edition, `CentreViewSwitch`; View ▸ View as … ⌃⌘1/2/3), moved here from the Book view's header; the **language switch** on a piece with translations (`LanguageSwitch`); the **running-round indicator** (`RunningRoundIndicator`, `RunningRound.line`), in every window on the book, naming what runs ("Translating · Serbian · “Chapter Three” (3 of 12), re-reading", or the pass's editor for a round), shortening to "Serbian 3/12" when narrow, and opening that chapter read in its language on a click; and the **right-column toggle** on the trailing edge. A second window's Run says a round is running and starts nothing (`TranslationRunStart.refusedIfBusy`).

**Why.** The design's standing places; the desk that showed run state is gone.

**Cost.** Four toolbar items; the leading reserve at the minimum width is estimated, not measured mounted.

### 14. Tests: one builder per view host, and the flake verdicts

**Decision.** A mounted test builds its view through its host's one builder (`MaughamTests/TestSupport/ViewHostFixtures.swift`; `HostBuilderCensusTests.test_noTestBuildsAViewHostByHand`, with a parity test that each fixture passes what production passes). The flakes: the image-paste failure was the general pasteboard, shared by every process, so tests paste from a pasteboard of their own through `MaughamTextView.paste(from:sender:)` (`TripwireGrepTests.test_noTestWritesTheGeneralPasteboard`, tripwire 60); the multiselect select-then-wait tests were culled (tripwire 33's shape); the figure-grid focus failure never reproduced in 50 runs and its premises are now asserted; a research note's debounce race was real and is fixed with an injectable clock (`ResearchNoteDoor.debounceWait`); and the canvas family's armed Escape arbiters were a test leak and a production one: a window that closed with a dimmed canvas kept its Escape monitor, and `WindowEscapeArbiter` now lets go on the window's `willClose`.

## Rulings made on the owner's behalf

Each was taken in the build ledger by the controller (or an implementer, where it says) and is the agent's, not the owner's, unless marked answered.

1. **A piece that would not read draws a hollow ring labelled "Could not be read"** (RULING-54's honesty rule; cost if wrong: one more glyph in the tree). *Unanswered.*
2. **The dot is accent, at the row's trailing edge**, not the plan's secondary grey beside the stage dot (the draft stage dot is already grey). Implementer's call. *Unanswered* (hand check 1).
3. **Filing settles a change**: Keep mine and Make it a rule leave the list like Fine; the change stays in the report. *Unanswered.*
4. **Compile: only problems that stopped a book are listed and mark the editions**; warnings stay behind Show Problems, so list and mark agree. *Unanswered.*
5. **A question clicked in an edition's list opens its paragraph in the edition's language.** Follows the owner's answer 3 of 2026-11-21. *Answered in substance.*
6. **Run Whole Book's cost is shown on the head's scope line, measured only while idle, with no confirm dialog.** *Unanswered.*
7. **Reading must not cost Undo**: type, switch to a language, switch back, ⌘Z works. Its consequence: no undo at all while reading. *Unanswered.*
8. **The arrow rule**: an arrow selects at once; it pulls up after a ~300 ms settle and only if the right column is showing; Return or Space pulls up now and reveals; Back records settled pulls only. *Answered* (owner's hand check, 2026-11-22: "look good").
9. **A palette card both pinned and inside a region lists under Palette** (the shelf's first claim); the misleading code comment was fixed. *Unanswered.*
10. **The insertion line is built** by sampling the pointer against the row's frame while targeted. *Answered* (owner's hand check, 2026-11-22).
11. **One promotion at a time per Collection**, refused at entry. *Unanswered.*
12. **A ledger written before `latestByPiece` falls back to the ring's finished rounds.** Implementer's call. *Unanswered.*
13. **A failed or refused compile with problems covers the centre with them**; a warnings-only book does not. Implementer's call, from hand check 4's wording. *Unanswered.*
14. **Adding a language the book already has selects that edition** and shows its Brief, rather than an alert. *Unanswered.*
15. **The Book row rolls up everything inside it.** *Answered* (the owner's instruction, relayed during Task 3).
16. **The plan's own calls** (the plan's "Calls made in this plan", 1–13): the design proposal in every edition; changes and glossary proposals carry the round's lifetime; source under each paragraph on by default; the view switch in the toolbar; the fold's tree-local tag; the promotion closes only what it moves; the flake verdicts; ⌘⌥L and ⌘⌥K; Earlier letters; the running-round indicator; a finished round is ended and not cancelled; the Source's Status shows publishing only; stale and left-over paragraphs as head lines. *Unanswered* (the owner answered the plan's four questions, below, not the calls).

**The owner's answers (2026-11-21):** the designer's Run at the head of the Source edition's To resolve; a chapter read in a language stays in it on the next chapter when it has the translation; a click on a chapter in an edition's Status opens it in the edition's language; drop-target feedback and the Canvas row's drop join the fold's task; Brief's how-to lines go ([ADR 0037](0037-brief-and-the-pulled-up-thing.md) decision 22).

## Owed to the owner

The controller gave the owner a sixteen-item list on 2026-11-22. That list's text is not in the repository; this is it reconstructed from the build ledger's "FOR DENVER" lines, the plan's calls and the earlier plans' owed decisions, with the owner's answers so far.

1. **The hand checks** in the plan ("Hand checks owed to the owner", 1–20, the smoke last). *Partly answered, 2026-11-22:* the single click on a fold card, the insertion line and arrowing with nothing pulled up "look good".
2. **Promotion carries nothing of the piece's history.** *Answered, 2026-11-22:* the history survives in the original (the Collection keeps it); the promoted project should also carry the history, notes and translations: a copy, not a move, of the op log, annotations and translations, planned as its own work after plan 4.
3. **"Changes" or "To look at"?** The chip and the Status column also count departures the translator never touched.
4. **Remove Edition.** There is no way to remove an edition; a mistyped language tag is permanent.
5. **A change made only in a language dots the edition's row, not the chapter's.**
6. **No undo while reading a translation** in that window, including undoing a note resolved in the right column (ruling 7).
7. **A palette card pinned and inside a region lists under Palette** (ruling 9).
8. **Publishing's edges:** problems cover the centre on a failed compile (ruling 13); a compile in any language resets the publication pick in every edition; a richer Source Status.
9. **The tree's dot:** accent at the trailing edge (ruling 2); it shares the unread dot's colour; Parts and the Book roll up.
10. **The hollow ring** for a piece that would not read (ruling 1).
11. **Filing settles a change** (ruling 3).
12. **Only stopping compile problems are listed** (ruling 4).
13. **Brief's foot:** its size, History without its clock glyph, and the links' count leaving the line at the narrowest width.
14. **Run Whole Book's cost on one line, no confirm** (ruling 6).
15. **One promotion at a time** (ruling 11).
16. **The earlier plans' open decisions:** the two "is running" lines' wording and Lock not locking the manuscript text ([ADR 0035](0035-the-subject-not-the-persona.md) decisions 7 and 14); a Check Writing button in To resolve's head ([ADR 0036](0036-to-resolve.md) decision 7); the choices "for the owner to overrule" in [ADR 0037](0037-brief-and-the-pulled-up-thing.md) decisions 18–22; and this plan's calls (ruling 16).

## Known limits

Not-done minors from every task, each with its reason.

- **Round letters.** An older build's rewrite of the rounds ledger drops `latestByPiece`, `ruled` and `translatorName` until the next round (derived file; no migration, tripwire 11). A peer Mac's ledger write arrives with no event until something re-renders (needs a file presenter on `.maugham/translations/rounds/`, a sync change). Main-actor reads of the ledger wait behind queued writes. Mid-preview, the head's standing letter is the round before the one streaming.
- **Presence and Status.** Each window walks for itself (they share one `ProjectStore`, not the walk). To resolve's own Book list still walks synchronously. A diagnostics re-read after a whole-book check is unmeasured. The dot ignores the list's filter (intended). A whole-tree re-render follows each marks change. A figure-anchored to-do never reaches the board (no producer makes one today). The to-do counts depend on `ResolvePresenceWiring` staying mounted. A click on empty board space does not take the keys. The board's "Open" column name, short pass headers and the stage word on untouched pieces were left.
- **The edition's centre.** A re-click on the already-selected tree row does not re-jump (the `List` delivers no write). `sourceLanguage` and the imprints refresh with the catalog, not on a hand edit of `config.json` while an edition is open. The host stats two files per redraw (never per row).
- **The edition's To resolve.** A Keep mine draft typed while that chapter's next round lands is refused ("no longer part of this round"), not misfiled. The Source head's Request Changes and Cancel wrap by construction (no live designer to measure). `DesignProposalStore.list()` stays on the main actor (small, `@MainActor` store).
- **Brief's foot.** Tab's reach to the foot's doors is unverified (hand check 18); VoiceOver reads the Details menu's empty value.
- **The desk's homes.** The Editions `+` is a one-item menu, the family's shape. ⌘⌥L where the scope has no questions shows To resolve with its filter unchanged.
- **Reading in a language.** The reading position blinks; VoiceOver's reach of the overlay's elements is unverified; the margin dots have no accessibility element (pre-existing); the toolbar's leading reserve is estimated. A choice made with no `Document` registered sets the language without a place (unpinned).
- **A piece in a language.** Questions off the open piece read without Reply (plan 2's rule; the head opens the chapter). A closed chapter's translation re-derives only on a translation event. A screenplay read in a language groups by paragraph, not scene. The Earlier letters choice resets when the faces change. The running state's width is unmeasured. The empty line and "N not translated yet" are not joined into one sentence (it would read the translation twice).
- **The fold.** A closed Collection script's Scenes miss a peer's sync until the next manifest change or local re-parse. A drop of several files is one undo step per file. Two open folds listing one item give two rows one tag (the tag needs the doc id, which touches every tag reader). Space during type-select toggles a selected fold row. The Canvas row's dot is per window and not persisted.
- **Promotion.** Two windows with the same piece open would hold two `Document`s on one path; unreachable today (`WindowGroup(for: URL)` opens one window per project). A load already reading when the staging moves run is closed, but may have rendered at the old path. `EditorHost`'s reload is pinned by a source census, not a mounted window (hand check 17).
- **Tests.** The parity census's environment spans are hand-named anchors; a new `.environment(\.` in an unnamed span would not be seen. The figure-grid focus failure was never reproduced; its fix is premise assertions, not a found cause.

## Not yet built

Plan 5 of the same milestone; the list is in the plan's "Plan 5" section. Nothing above depends on it.

- The margin setting and the amendment to [ADR 0027](0027-the-compiler-and-the-editor-boundary.md) §1.
- The whole-menu review (⌘↓ has no menu item; File ▸ Add Language…; the titles of ⌘⌥L and ⌘⌥K; two "Outline" items, ⌘⌥O and ⌃⌘2; ⌃⌘1/2/3; ⌃⌘L and View ▸ Read In; Show Source Under Translation has no key).
- The guide, the welcome tour, the cheat sheet and Claude's help text. **The bundled in-app Help still describes the desk and the review pane, and the branch does not merge until it is rewritten.**
- Figure source-changed items in To resolve.

## Consequences

- To resolve's list is reachable on every subject; 0037's interim homes and interim loss are closed.
- An edition is a subject with its own book, Status, To resolve and Brief; the desk is gone.
- A piece can be read in any language it has, with its source under each paragraph, and its raised items in that language are its To resolve.
- The tree answers "what needs me?" with nothing open, at a cost measured and moved off the main actor.
- A Collection window survives a promotion, whatever its outcome.
- No op-log schema change (`ProjectManifest.currentSchemaVersion` stays 10) and no MaughamCore change: plan 4 forces no paired phone release.
