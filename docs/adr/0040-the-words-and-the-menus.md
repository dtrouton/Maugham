# ADR 0040 — The words and the menus: one noun for a piece, one vocabulary, a menu bar walked by its census, and help that describes the window that ships

**Date:** 2026-11-26 · **Status:** Accepted · **Milestone:** shell-without-personas, plan 5b (branch `claude/shell-without-personas`) · **Design:** `docs/superpowers/specs/2026-11-16-subject-resolve-brief-shell-design.md` · **Plan:** `docs/superpowers/plans/2026-11-22-shell-p5-menus-wording-help-margin.md` (Tasks 6–10; the approved menu table is in it) · **Builds on:** [ADR 0035](0035-the-subject-not-the-persona.md), [ADR 0036](0036-to-resolve.md), [ADR 0037](0037-brief-and-the-pulled-up-thing.md), [ADR 0038](0038-status-editions-and-translation.md), [ADR 0039](0039-read-through.md)

## Context

Plans 1–4 and read-through rebuilt the window without personas, but its words were older than it. A piece was "this piece" in a novel, a to-do was a "task" in the Undo menu, a note was an "annotation" in History, the left column was "the tree" in some strings and "the binder" in others, and three buttons all said "Run". The menus still carried the old panes' titles, two items were both called "Outline", one key (⌘⌥H) had silently never been bound, and the bundled guide, tour, samples and Claude's help still described the persona bar, the Inspector and the Department desk. [ADR 0035](0035-the-subject-not-the-persona.md)–[0038](0038-status-editions-and-translation.md) made the rewrite a merge condition.

Each decision below is marked **the owner's** (Denver decided it) or **the agent's** (a ruling taken in the build ledger, his to overrule; cost-if-wrong is cheap in each unless said).

## Decision

### 1. The piece's noun, asked of one function

`PieceNoun.of(_:in:)` (`Maugham/Views/PieceNoun.swift`) is the only place a piece's word is spelled: Novel *chapter* (group *Part*), Short Story *story*, Collection *piece* (a `.fountain` piece *script*), Screenplay *script*, Report *section* (group *Part*). It answers `singular`, `plural`, `group`, `capitalised` and `counted(n)`; the plural is never `noun + "s"`. Every writer-facing sentence that names a piece asks it (To resolve's groups and head, History, Status, Statistics, Brief, the binder's creation verbs, research questions, the translator's buttons). *Story, section and Parts* are **the owner's** (question 3, 2026-11-22). The Screenplay plural *scripts*, not the plan table's *scenes*, is **the agent's**: every plural counts files (a round, a board row), never sluglines. `WordingCensusTests.test_noUserFacingStringHardCodesAPieceNoun` bans "chapter" in any app string literal outside the function (named allowances: a new novel's first title "Chapter 1", typesetting terms in `EmissionContract.swift`), and `test_oneNounFunction` keeps the function single. A string that names no particular project says "piece" (MCP descriptions, the tour).

### 2. One word per thing

- **"the binder"**, never "the tree", in every writer- and Claude-facing word (**the owner's**, question 4); "tree" stays in code.
- **"to-do"**, never "task", in the app (the agent's): Undo titles, History rows, the New To-Do sheet ("This Chapter | The Book"), "Make a To-Do". MCP keeps `task` as its wire noun (`list_tasks`, `get_task`), and its descriptions say "a to-do (a task, on the wire)".
- **"note"**, never "annotation", in writer-facing text (the agent's): History's chip "Notes", "Undo Reject Note", the guide page "Notes & Suggestions" (slug `annotations-and-suggestions` unchanged). MCP tool and field names keep theirs (`list_annotations`, `annotation_id`).
- **Research's two homes** (the agent's): "Whole-Book Research" and "This Chapter’s Research" (by the noun) wherever a target is offered (Format ▸ Table ▸ Send to Research, the Inbox's Promote to Whole-Book Research); "Shared Research" and "This Piece’s Research" are gone. Whose a note is, and how it moves, is [ADR 0037](0037-brief-and-the-pulled-up-thing.md)'s "Research is the book's or a piece's" (the research rule and its one oracle are recorded there, not here).
- **The rounds**: the translator's **Translate This Chapter** (by the noun) and **Translate Whole Book** (**the owner's**, question 1), with "round" kept as the record's noun ("Serbian · round 3"); the editor's **Run Round**, titled for the pass in File ("Run Gould's Round", approved table row 6); the designer's **Run Design** (the agent's). The board's column is **Notes open** (the agent's).
- `WordingCensusTests` holds each: retired surface words (inspector, pane, desk, Department, translation review, synopsis, corkboard, Task, the tree), "task", "annotation", "this piece", "Shared Research", "New To-do", and `test_theGuideQuotesNoReplacedAppString`, so the guide cannot keep quoting a string the app replaced.

### 3. The menu map

The approved table (plan 5, "The menus, on paper") is built whole: **approved by the owner 2026-11-25**, the four ★ rows his (row 7 File ▸ Translate…, rows 11/58 New Chapter / New Part by the noun, row 31 ⌃⇧⌘L) and every other row the agent's, approved as proposed. Since the table:

- **History is ⌃⌘H** (the agent's): ⌘⌥H is macOS's Hide Others, SwiftUI had silently given the item no key, and the keystroke hid every other app. The census found it.
- **Edit ▸ Comment… ⌘⇧K** (the owner's addition; the key is the agent's), also on the text's right-click.
- **⌘⌥K reads "To Resolve: Serbian Edition"** (disabled "To Resolve: An Edition"), the shape of its siblings "To Resolve: Questions" (the agent's, reversing the table's possessive "Serbian Edition's To Resolve").
- **View ▸ Margin ▸ People's Notes** (the agent's; it was "My Notes", which also drew an admitted reviewer's notes; the stored value `myNotes` is unchanged).
- **View ▸ Open in Centre has no key equivalent** (the agent's, plan call 7): as a menu key ⌘↓ would take "end of document" from every text view; ⌘↓ stays the binder's own key and the cheat sheet teaches it.
- **With no project window in front**, every File, Edit, View and Help item that acts on one is disabled, the four runs excepted (`MenuBarAvailability`, row 57).

### 4. The census reads the real menu bar

`MenuBarCensusTests` walks the menu bar the app actually builds, not the source (plan call 10): **every key is bound once** (its overlap allowance is empty; Fill Right takes ⌘R only inside a grid and shows no glyph); **every key the source declares is on its item** (`DocSyncTests`' extractor, a key held in a named constant resolved), which is how a key silently lost to the system is caught; every bound key has a cheat-sheet line and a `reference.md` row, and the cheat sheet teaches no key the menus do not bind; no title repeats within one menu; every item that acts on a project window is disabled with none in front. Each check has a planted offender and a control. A curated cheat sheet became a complete one.

### 5. One answer for what a selection is offered

`AnnotationOffer.kinds` (`Maugham/Editor/AnnotationOffer.swift`) answers the text's right-click and read-through's floating toolbar alike, so one selection never gets two sets of offers (the agent's ruling): where the writer may edit the words and they are not in read-through, **Comment…** only; where she may not (someone else's piece, read-through), Comment, Suggest, Query and Translator's Note; over a translation, Translator's Note only; with no posture, nothing. It reads the posture, never a permit rung (tripwires 47, 51).

### 6. File ▸ Translate… carries its own target

`TranslateMenuOffer` is built from the scope To resolve shows (`ResolveScope.shown`, one function for the pane and the menu): a piece read in a language offers that chapter, a translated edition faced offers the whole book, anything else is a disabled "Translate…" with a tooltip. The ask carries the offer (`ResolveRequest.translate(TranslateMenuOffer)`); a head runs only an ask for itself, an ask that no longer matches what To resolve shows is said and starts nothing, and a scope change drops a pending ask. The offer re-reads when an opened piece finishes loading. No key (approved row 7).

### 7. Help describes the window that ships

The guide, the welcome tour, the samples, the syntax sheets, the skills and the MCP descriptions were rewritten for a writer (Tasks 8–9). Guide slugs changed: `right-pane` → `right-column`, `translation-review` → `translation`, `publish-department` deleted (plan call 8); the developer half of the publishing page moved into a new served skill, `publishing-setup`. **The guide's merge gate is now a census, not a promise** (the agent's): `HelpWordsCensusTests` fails the gate on any retired word in the bundled guide, skills, samples or syntax sheets (persona, Inspector, Department, desk, translation review, review pane, the old panes, This Piece, ⌘4, segment, Pull Up Previous, Lock Research, Toggle Review Mode, pane, the tree), reads the tour's cards, every MCP description and schema and the `initialize` instructions as values, checks that every key a sample names is on the real menu bar and every key a tour card names is on the cheat sheet, and — over everything shipped (`Maugham/Resources/**` and the string literals of the Mac app, the phone and MaughamCore) — that **the owner's name and his books' titles never ship** (`test_nothingShippedNamesTheOwner`; the guide's examples say "Alex"; the updater's GitHub handle is allow-listed as an address). Every guide paragraph over 150 words was broken up (by hand; no census holds the length).

### 8. Claude Desktop is told at `initialize`

MCP `initialize` now sends `instructions` (`MCPInitializeHandler.instructions`, spelled once, at most 125 words, pinned by `MCPProtocolHandlersTests.test_initialize_sendsTheServersInstructions` and read by the help census): what Maugham is, that Claude never writes manuscript text, that a multi-step job starts with `get_help` topic "skills", and that Claude speaks in what the writer sees (the binder, the centre, To resolve ⌘1, Brief ⌘2, Pulled up ⌘3) and the project's own word for a piece. **The agent's ruling**: the bootstrap skill reaches Claude Code only, so Claude Desktop had no such guidance. No tool was added or removed.

### 9. The closing round: the open piece, Help without a project, where research went

**Who may read the faces is a counted list** (`FacesReaderCensusTests`, the agent's; the milestone review's I1/I2 and the shape's third appearance). `WindowSubject.faces` is the right column's subject; every act about the text being typed — ⌘S, ⇧⌘S, ⌘⌥C, the line above the prose and its drift mark, ⌘/ — reads the open piece through one resolution (`WindowSubject.openPiece`/`openDocId`, `CheckpointTarget`), and ⌘R checks the open piece when one is open ([ADR 0035](0035-the-subject-not-the-persona.md), Run, amended). Each production file reading `.faces` is named with a count and a reason; a new reader fails the gate, with a planted offender and a control.

**Help ▸ Syntax & Keyboard Shortcuts and Set up Claude Desktop… work with no project window** (`HelpSheetRoute`; changes approved row 57's "disabled with none in front"): with a project window in front each is that window's sheet, as before; with none, each opens a small window scene of its own, the syntax sheet on Markdown. `MenuBarCensusTests` reads every menu's item structs (File, Edit, View, Insert, Format ▸ Table, the `Focused*` structs, Help) and names these two as the window-free exceptions beside Run's four.

**The Research section says where the rest went** (`ResearchHomes.underAPiece`, derived with the homes and cached on the manifest): one quiet line at its foot, "12 notes are with their chapters — open a chapter’s fold to see them." in the project's noun, after "No whole-book research." when the section is empty.

## Gone by design

- "Toggle" titles (Focus Mode and Full-Screen Focus are checked items; Show/Hide Research Preview by state), "Outline" as a second item (⌘⌥O is Go to the Book), the bare-noun place items (Research, Palette, Inbox are "Go to …").
- The tour's promise that Focus Mode "hides everything but the words": outside the canvas it hides the toolbar, the status line, the line above the prose and the margin, and keeps the binder and the right column (said true in the tour, the sample and the guide; whether to change the behaviour is open, below).

## Consequences

- A new writer-facing string that hard-codes "chapter", says "task" or "annotation", or names a retired surface fails the gate; so does a guide page that names one, a menu key bound twice or lost, and a shipped mention of the owner.
- A Claude that cached a guide slug from before this branch asks `get_help` for the list again.
- The plan's hand checks (section H of "Hand checks owed to the owner") are the owner's one sitting for this plan.
- No op-log schema change, no MCP tool added or removed, no MaughamPhone source changed by this plan.

## Open, the owner's

Decisions the build left to him; each is built as described above until he says otherwise.

1. **Two "Ask about…" fields in one head** (the round's under Run, the check's in the check's line): a writer will type into the first one she sees. A design question.
2. **Help's two sheets open without a project** (section 9; the agent's, changing approved row 57, which disabled them with no project window): first run has only the Welcome window, and the guide's first setup step is Help ▸ Set up Claude Desktop….
3. **File ▸ "Save" or "Save Checkpoint"?** The item keeps "Save" for the ⌘S reflex (row 3); the cheat sheet says "Save Checkpoint", which is what ⌘S does.
4. **The Welcome window's sentence-case buttons** ("New project…", "Open project…") against the menus' title case.
5. **⇥ / ⇧⇥ to the canvas** works only in a novel's binder.
6. **Republish** renders the book as it stands now in the earlier edition's design; the old words are in the earlier file in Exports. Is that what "republish an earlier edition" should do?
7. **Focus Mode** keeps the binder and the right column outside the canvas. Should it hide them?
8. **"New Story" / "New Section"** (a short story's and a one-document report's creation verbs).
9. **Suggest… everywhere, or only where the writer cannot edit** (`AnnotationOffer.kinds`, section 5; one line).
10. **"Where a note is, is whose it is"** ([ADR 0037](0037-brief-and-the-pulled-up-thing.md), the research rule): the agent's ruling of plan 5's closing round A, told to the owner; reversible.
11. **"People's Notes"** for the margin's first setting (asked, unanswered; built as recommended).
12. **MCP `instructions` at `initialize`** (section 8): told to the owner; one string to delete if unwanted.
13. **`move_research_item` cannot give a novel's note to a chapter** (its `target_document_id` is Collection-only); Claude is pointed at `link_research`, so one verb has two MCP spellings by project kind.
14. **Screenplay plural "scripts"** (section 1), departing from the approved table's "scenes".
15. **A dense To resolve list and a clicked margin mark**: the list gives way to the clicked note's own source, not "All", since a dense list has one chip by design. Should dense lists gain an All?
16. **Claude's notes on a reviewer's copy** are not drawn beside the text in read-through either: kept by the owner "for now" (2026-11-25, [ADR 0027](0027-the-compiler-and-the-editor-boundary.md)'s amendment).
17. **The Inbox at scale** ([ADR 0035](0035-the-subject-not-the-persona.md); the design's open decision): not mocked.
18. **⌘⌥K's title.** Row 35 as approved read "Serbian Edition’s To Resolve"; it is built as "To Resolve: Serbian Edition", the shape of its siblings (the filters' colon), because a re-review found the possessive read as a different kind of item. The agent reversed an approved row; one string (`EditionWiring.keyTitle`) to change back.
19. **Task 4a's rulings R1–R6**, made for the owner to confirm (R7 he confirmed): a Collection piece's link to shared research draws the note in the piece's fold, and a drop on the section unlinks it (R1); research in a `pieces/…/research/` folder no live piece owns is the book's (R2); "Move to Chapter" is a submenu listing the chapters, and link verbs are for a single row (R3); a fold opens by itself on a tree selection only, never from Find, ⌘⌥E or navigation (R4); a fold-to-section drop leaves the note where it lives in the research tree (R5); a single-document project keeps its fold listing every research item beside the section (R6).
20. **A group's Delete and Move act only on what the section shows under it**: notes a chapter holds stay with their chapter, and the confirm says so (Task 4a, I2).
21. **New Note on a view-only share is refused by an alert**, not hidden (Task 4a; hiding it per row was not cheap).
22. **⌘R checks the open piece** when one is open (section 9; the agent's, amending plan 1's preference for the faces).
23. **The Research section's "where they went" line** (section 9; the agent's).
24. **The Inbox's fast "Promote to Research for “…”" is removed** (the agent's): it was reachable only after a Brief link with the Inbox open, and filed into a piece the writer only glanced at. Promote to Whole-Book Research and Promote to Research for… stay.
25. **The phone's wording** ("Annotations", "This piece") waits for the next paired release (the owner's ruling); until then the two devices name the same things differently.
