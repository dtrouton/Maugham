# The window without personas: subject, To resolve, Brief

*Design, 2026-11-16. Approved by Denver the same day. The open decisions at the end wait for later plans.*

*Inventory behind it: `docs/superpowers/notes/2026-11-16-shell-surface-audit.md`. Mockups (untracked): `.superpowers/brainstorm/29006-1794818289/content/`, most usefully `right-column-three-faces.html`, `density-bare-normal-extreme.html`, `translation-screenplay-collection.html`, `intent-loop.html`, `brief-essay.html`.*

*This would supersede the persona parts of ADR 0005 as amended by ADR 0025, and ADR 0031 (the persona as an input to the run). It needs its own ADR when built.*

## Why

The four personas (Plan, Author, Review, Publish) read as a pipeline the window moves through. A book is never at one stage: one chapter is being drafted while another is on its third pass. Stage is a property of a piece, not of the window.

Underneath, the personas do a different job: pruning. The right column has many panes that are peers (Inspector, Annotations, History, Tasks, Inbox, Translation, Intent, Visual Language, What I've Learned, First Reader, Diagnostics, References, Department), and each persona shows a subset so the row stays short. The window grows by panes; each milestone added one. Rearranging the switcher (a top bar, a side rail, a tab row) does not reduce what is being switched between. There have to be fewer kinds of thing.

A persona also bundles unrelated settings: what the centre shows, whether it is editable, what Run means, what a double-click does, and where a research item or a figure lands (each has four answers today).

## Goals

- The same gesture does the same thing everywhere.
- A new chapter shows almost nothing beside the text. Most writing hours look like that.
- A writer can answer "what needs me?" for a chapter, a part, the book or an edition from one place.
- The intent loop (things are raised, the writer decides, decisions stand, the next check reads them) is visible as one loop.
- A translator's or editor's letters can be followed chapter by chapter.

## Non-goals

- No change to what is stored about manuscripts, the op log, permits or posture. The hard invariants in `CLAUDE.md` stand.
- No change to the phone.
- No new capability for Claude. The membrane holds: Claude never writes a statement, and MCP never writes manuscript text.
- Not a visual redesign. This is structure; styling follows the existing app.

## Anti-goals

- A long row of peer tabs or toggles returning under another name.
- Any surface that is a bag of "everything about this chapter". The inspector was one; an early "shelf" in this exploration was another.
- A rule that asks which mode the window is in.
- Density rules that add furniture to a quiet chapter. They may only appear when content demands them.

## The model

1. **The tree picks the subject.** Everything the window can be about is a row in the tree.
2. **One click rule.** A click goes to the thing without discarding the centre if it can avoid it:
   1. if the centre already contains the thing, it is found there;
   2. if it is reference material, it opens beside the centre;
   3. otherwise it becomes the centre.

   A double-click always opens the thing in the centre, and every beside view carries a visible "Open in centre" control.
3. **The right column has two faces and one pulled-up thing.** *To resolve* is what has been raised about the subject. *Brief* is what the subject is held to. The third position holds the one thing the writer pulled up from the tree.
4. **Scope follows the subject.** A chapter's faces show that chapter's; a Part's show its chapters'; the Book's show the whole book's; an edition's show that edition's.
5. **No behaviour asks a persona.** The personas, the persona bar and the per-persona pane lists go.

## The tree

Rows, in order: the Book; Inbox; Canvas; the manuscript (Parts and pieces; a screenplay's scenes); Figures; Research; Palette; Editions; then the existing foot (Trash, Removed Elsewhere). Find stays an overlay.

- **A piece's fold** holds its material: its research, its canvas cards, its palette pins, its figures and its links. Past roughly six items the fold shows collapsed groups with counts (Research, Cards, Palette, Figures) instead of rows.
- **A novel's fold holds links to shared research; a collection piece's fold holds research it owns.** These must not look identical. *(Builder: how they differ visually is open.)*
- **A row shows a stage dot and, when it has anything to resolve, one dot.** Never a number. Numbers live in Status views.
- **Two row states:** the row open in the centre, and the row last clicked. They differ when a click was answered by clause 1 or 2.
- **The Book's long statements** (book intent, What I've Learned, First Reader, Visual Language) are reached from the Book's Brief and open as the pulled-up thing. They need no tree section of their own.
- **Editions are one row per language**, derived exactly as the desk's language rows are today (`EditionStatus`), plus the source language. There is no stored "edition" to list, and this design adds none. Formats, imprints and a bilingual body (a `LanguageSet`) are choices made at Compile… inside a row. *(My call.)*
- **A row's stage dot is `ReviewStatus`** (derived from the passes, coloured by `StatusSwatch`), not `DraftStage`.
- **A Part has no intent of its own.** Statements are project- or document-scope only, and this design adds no scope. A Part's Brief is its chapters' decisions gathered. *(My call.)*
- **Dragging onto the tree** keeps its existing classifier (`TreeDropIntent`). Because one tree now takes reorders, card binding, capture filing, research linking and figure sends, the drop target must say which is about to happen.

## The centre, by subject

| Subject | Centre |
|---|---|
| The Book, or a Part | Views: Cards, Outline, Status. A Part is a small Book over its own chapters |
| A piece | The editor |
| A scene (screenplay) | The script, scrolled there (clause 1) |
| Canvas | The canvas. Clicking a piece lights its bound region and dims the rest (clause 1), as Plan does today |
| A figure | Its grid or image. A figure is manuscript content, so it takes the centre *(my call)* |
| Research item, palette card, canvas card | Beside (clause 2) |
| Inbox | The captures. Filing is a drag onto the row a capture belongs to, with a File… button as its visible twin |
| An edition | Views: Book (the typeset pages), Status. The design gate, round report parts, problems and notices keep covering the centre in their existing order. Clicking a piece scrolls the book to it (clause 1) |
| Palette | The wall |
| A piece in another project (collection reference) | Its placeholder, as today |

**Status** is today's review board widened: pieces down the side; stage, passes, open notes and open to-dos across. For an edition: translated, last round, questions, changes to look at, trend. This is where the old pipeline remains visible, as a property of each piece.

## To resolve

One list of what has been raised about the subject and is waiting on the writer.

- **Contents:** notes from rounds, a check's findings, the writer's own to-dos, translator's questions and changes, glossary proposals, a design proposal awaiting a decision, compile problems, and a figure's "source data changed".
- **Head of the list:** where the subject stands (the pass ladder, with its ruling) and the latest letter (the coach's, an editor's, a translator's), then Run.
- **Filters by source**, not tabs: each pass, Mine, Checks, Questions.
- **Nothing from this list is drawn on the manuscript.** Constitution must-not #2 (*identity*) and ADR 0027 §1 forbid it: "no overlay, no margin note, no gutter mark… no decoration on the paragraph a note is about". An earlier draft of this design drew marks and a popover; that was a collision with an identity principle and is withdrawn. Locality comes from the list instead: it follows the cursor, and a row's click moves the caret (the editor receives a position, never a payload). The writer's own inline to-dos are text they typed and are unaffected.
- **The margin is a setting with three positions, off by default** (View menu, remembered per project; not a toolbar control). *Off*: nothing. *My Notes*: a note signed by a person (the writer, a human reviewer; decided by the actor key that sealed it, never guessed) shows as a dot and a tint on its words. *Everything Flagged*: adds one grey tick beside any paragraph carrying an item from a check or a round. The tick is a position and never content: the same tick whatever the item says and however many there are, no words, no tint, no count; a click moves the list to that paragraph and opens nothing in the editor; it follows the list's filter; focus mode hides the margin whatever the setting. **Everything Flagged requires an amendment to ADR 0027 §1**, which lists "no gutter mark" among what was built. The precedent is the line above the prose, which already carries "intent may trail the draft", an app-drawn mark derived from a check's verdict with none of the model's words. The amendment would say: a wordless, opt-in position mark is permitted; anything carrying model content is not. Denver approved all three positions and the amendment (2026-11-16).
- **Grouping:** "Whole chapter" for items not at a paragraph, then by paragraph. A screenplay groups by scene. At Book scope, by piece, with book-level to-dos first.
- **Two lifetimes, visibly different:** a check's findings are replaced by the next check; everything else stays until settled.
- **Density rules, which do nothing on a small list:** past roughly a dozen items the filters become single-choice, so one source is worked at a time; the group for the paragraph or scene under the cursor opens and the rest collapse to counts.
- **With the right column hidden or in focus mode, nothing is shown.** That is the existing behaviour and the point of focus mode.
- **Lock** replaces Review's read-only centre: an explicit toggle, per window, not remembered across launches, covering the text and the research and figure surfaces Review locks today *(my call)*. Posture still locks what the writer may not change, with no toggle.
- **Inbox, admission requests and load questions are not here.** Captures belong to no piece yet; the other two block and stay sheets.

## Brief

What the subject is held to. Only what the writer wrote about it.

For a piece, in fixed order:

1. **A line (optional).** One sentence for the corkboard card, the outline and the line above the prose. When absent, those show the opening of the intent.
2. **Going for.** The intent, as prose, editable in place. It is often several paragraphs. The latest check's reading is marked on its own sentences: no mark where the draft does it, a solid mark where the draft pulls against it, a dotted mark where the draft says nothing about it. The data exists: a check stores a `ClauseStatus` per clause (`holds` / `strains` / `silent`) with the writer's sentence quoted (`DiagnosticIngest.ClauseStatus`), so a mark is found by matching the quote. The mark is app-drawn from one of three words and carries no model text; clicking it jumps to the item in To resolve, where what the check said is shown. The marks show only while Brief is in the right column, never when the intent is opened in the centre, and never on the line above the prose (ADR 0027 §1). Denver ruled this within must-not #2 (2026-11-16); it should be recorded in the ADR that amends 0027.
3. **Decided.** The writer's dated decisions, newest few showing, the rest folded.

Then two quiet lines that open in place: what applies from the Book (or collection), and what Claude has read off the text and the writer has not confirmed.

- **Answering moves an item across.** Answer, Add to intent, Keep as lesson, Make it a rule and Confirm each take something raised in To resolve and file it under Decided in the right Brief, in the writer's words. Because the destination may be out of sight, each says where it filed ("Filed under this chapter's intent").
- **The Book's Brief** is the book's intent plus every standing decision in the book, filterable by where it was made: the book, each piece, the lessons ledger, the first reader, each edition. This single view does not exist today.
- **An edition's Brief** is its edition brief, glossary, cast and visual language.
- **The line above the prose stays.** It is the Brief in a sentence and carries the "intent may trail the draft" mark. Clicking it opens Brief.
- **Open in centre** for writing an intent at length.

What leaves the old inspector: word and page targets go to the status line under the text; tags go to the Outline view as a column and to the row's menu; links go to the fold; per-piece publishing settings go to the edition's Status view.

## The pulled-up thing

The third position in the right column holds one item from the tree: a research note, a canvas card, a palette card, a figure, one of the Book's statements, or History. It brings its own details (a note's citation and versions; a figure's uses). It stays until closed, across subject changes *(my call)*. It generalises today's study column.

When the Canvas is the centre, the faces have nothing to show; the right column shows the selected card's or region's details there.

## The toolbar

No persona bar. It carries: the centre's view switch where the subject has views; a language switch on a piece that has translations; Lock; and a standing indicator for a running round, since one round runs at a time across the whole book.

## Translation

- **A piece switched to a language** shows that language's text, read-only, with the source under each paragraph (can be turned off). Its To resolve is that language's questions and changes for that piece, headed by that round's letter. The separate translation review mode goes.
- **The edition's Status** lists every piece's latest round, and its To resolve gathers questions by piece.
- **Round letters must be kept per piece.** Today the desk shows only the newest round per language and the store keeps a short ring per language across all documents, so after a whole-book run most letters are unreachable. The requirement is the latest finished round per piece per language, always reachable, with the existing ring as history; kept where rounds are kept today (local, derived, under `.maugham/`) *(my call)*. This is a storage change and the one place this design reaches below the view layer. The same applies, more mildly, to editors' rounds.

## Project types

- **Collection:** the model's best case. A piece owns its research, stage and Brief. A script inside a collection always shows a grouped fold (Scenes, Research). A piece in another project is a blank row in Status. A piece owned by someone else is locked by posture.
- **Novel:** as mocked. The fold holds links.
- **Screenplay:** one file, so one stage, one pass ladder and one Brief for the script. A scene is a place, not a thing: no stage dot, no fold, no Brief. Its dot is derived from where items fall. Status has little to show. The density rules are effectively always on.
- **Report:** not examined. Expected to behave as a novel with more figures in each fold.

## Where today's surfaces go

| Today | Becomes |
|---|---|
| Annotations, Diagnostics, Tasks, Translation's queries | To resolve |
| Intent, the intent strip, the inspector's synopsis | Brief |
| The inspector's pass ladder | Head of To resolve; also Status |
| What I've Learned, First Reader, Visual Language | Reached from the Book's Brief; open as the pulled-up thing |
| References, the study column, research and figure inspectors, History | The fold, and the pulled-up thing |
| Department desk | The edition's two faces |
| Inbox pane | The Inbox row |
| Review board, corkboard, outline | Views of the Book |
| Book preview and its covers | The edition's centre |
| Persona bar, per-persona pane lists and memory, This Piece / All Pieces, the palette wall's travelling door, double-click-travels-only-in-Plan, research and figure placement by persona | Gone |

Unchanged: posture surfaces and the standing line, banners and pills, the ⌘S flash, rewind, restore, checkpoint, admission, claim and settings sheets, the Statistics, Help and Settings windows.

## Constraints

- **`EditorHost` and the canvas keep one mount each and their identities across every subject change** (`Maugham/Views/AREA.md`, "The centre column"; tripwires 6, 27, 30). Subject-led routing changes what `centreRoute` is asked, not that rule.
- **A Brief's intent editor is a second editor in the window** and follows the existing statement-host rules (`Maugham/Editor/AREA.md`, "Two editors in one window").
- **No uncached per-row work** (tripwire 4). Tree dots and Status need per-piece aggregates without opening documents; the board's open-notes aggregation is the precedent, and to-dos and translation need the same.
- **Hide, don't disable; ask `Posture`** (tripwires 47, 51). Unchanged.
- **The right column is 240–480pt.** Three positions fit as a segmented control only with icons or truncation; a long pulled-up title truncates in the middle.
- **Nothing AI-produced renders in the editor or its chrome** (constitution must-not #2, ADR 0027 §1). To resolve and Brief are the companion pane the constitution permits. One MCP tool description names "the Plan persona on screen" (`CanvasTools.swift`); it becomes "the canvas is the centre".
- **The faces follow the piece.** When clause 1 answers a click on a piece (the Canvas or an edition is the centre), To resolve and Brief show that piece's; in an edition, that piece's in the edition's language. When clause 2 answers (reference material), the faces stay with the centre's subject. So the window's subject becomes two values, what is open and what the faces are about, where `BinderSubject` is one today.
- The persona censuses and tests (`PersonaPaneRegistryTests`, `CentreRouteTests`, the persona tripwire greps) are retired or re-made, not patched.

## What Denver decided

- The pipeline framing is the problem; a side rail of the same four modes was rejected as the same thing rotated.
- The tree as the picker, with canvas and editions in it.
- One filtered list for things to resolve.
- No shelf: collected material must not become a grab bag.
- The density behaviour (bare, normal, extreme with the four rules).
- The screenplay may be a thinner form of the same window.
- Brief cut to line, intent and decisions; tags are little used and may move.
- Intent is an essay and stays prose; the short line is optional.
- A click on a chapter while the Book's Cards, Outline or Status is the centre opens the chapter. Clause 1 of the click rule applies to places you work in (the Canvas, an edition, a script), not to overviews you navigate from.
- A research note or card opened beside the text is editable there. That is a third editor in the window, beside the manuscript's and a Brief's intent.
- The check's reading is marked on the intent's sentences in Brief, in the right column only (B1).
- The margin setting has all three positions (Off, My Notes, Everything Flagged), off by default, and amending ADR 0027 §1 is part of this work.
- Run is two explicit commands: ⌘R runs a check; Run round is its own command and the button at the head of To resolve. Nothing infers which from the window's state.
- ⌘1–4 stop being persona keys. ⌘1 is To resolve, ⌘2 is Brief, ⌘3 is the pulled-up thing; ⌘4 is free.
- The check's reading may be marked on the intent's own sentences.

## My calls, for Denver to check

- Editions are rows per defined edition; formats and imprints live inside.
- A figure takes the centre when clicked.
- The pulled-up thing persists across subject changes.
- A Part row behaves as a small Book.
- Tree rows show a dot, never a count.
- The thresholds (about six for the fold, about a dozen for single-choice filters).
- The Book's statements hang off the Book's Brief, with no tree section.
- Targets to the status line, tags to Outline, links to the fold, publishing settings to the edition.
- An existing synopsis carries over as the optional line. Claude's tools only read the synopsis (in the project structure listing, `ProjectTools.swift`); none sets it, so the listing reads the optional line, falling back to the intent's opening.

## Open decisions

1. **The Inbox at scale** (dozens of captures) has not been mocked.
2. **The ⌘⌥ pane shortcuts**: what each maps to.
3. **Teaching it:** the welcome tour, the guide, and the help Claude reads all describe four personas.

## Left to the builder

Layout within each face; the visual difference between check items and durable items, and between linked and owned folds; icons; how views are remembered per subject kind; the order of work.

**Order of work (Denver's ruling, 2026-11-16): slices exist only where validation needs them; nothing is built to be replaced.** One branch, merged when whole. (1) The subject replaces the persona: routing, tree rows, the click rule, Lock, Run; personas deleted. (2) The right column: To resolve, Brief, the pulled-up thing, the fold. (3) Status views, scope at Book, Part and edition, translation, round letters per piece. (4) The margin setting and its ADR, the guide, tour and help. Denver validates by hand after (2) and at the end. Each plan is written against the code the last one left.
