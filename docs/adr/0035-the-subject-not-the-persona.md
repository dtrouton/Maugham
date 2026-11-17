# ADR 0035 — The subject, not the persona: the tree decides what the window shows

**Date:** 2026-11-17 · **Status:** Accepted (plan 1 of a multi-plan milestone; see "Not yet built") · **Milestone:** shell-p1-subject-takes-over (branch `claude/shell-without-personas`) · **Design:** `docs/superpowers/specs/2026-11-16-subject-resolve-brief-shell-design.md`

## Context

[ADR 0025](0025-persona-shell.md) gave the window four modes (Plan, Author, Review, Publish, ⌘1–4). Each reconfigured all three columns, remembered a right-pane segment, and decided what ⌘R meant ([ADR 0031](0031-the-persona-is-an-input-to-the-run.md)). The writer had to know which mode a thing lived in before going to it, and a click on a tree row could mean a different act in each mode. The tree already carried a subject (`BinderSubject`); the mode was a second answer to the same question.

## Decision

The window has no modes. What it shows is a function of what the writer pointed at, and every act is named by its command, never inferred from where the writer stands.

### The window subject

`WindowSubject` (`Maugham/Models/WindowSubject.swift`) has three parts, each a `BinderSubject`:

- `open` — what the centre shows.
- `faces` — what the right column is about.
- `beside` — reference material opened beside (optional).

`WindowSubject.book` is `open = faces = .project`, no `beside`. `validated(…)` turns a part naming something that no longer exists into the Book (`open`, `faces`) or nil (`beside`). `lastClicked` is whichever of `faces` and `beside` was written last (`besideIsLatest`, kept by a `didSet` on each and saved with the subject): `beside` persists across clicks, so a piece clicked after a note is what the canvas lights and the tree outlines.

### The click rule

`ClickRule.resolve` is the one rule that turns a tree click into a `WindowSubject`; `centreRoute` (`Maugham/Views/CentreRoute.swift`) answers what the centre draws from the subject's `open`, the Book's view and the publish state (preview, proposal, round, problems), as one exhaustive value.

| Click on | Result |
|---|---|
| the row already `beside` | dismisses it: `beside` becomes nil, nothing else moves |
| a research item | it opens `beside`; `open` and `faces` stay |
| a piece (a document) while `open` is the canvas or an edition | `faces` moves to the piece; `open` stays |
| a piece otherwise | `open` and `faces` both become the piece |
| a Part (group), the Book, a figure, Inbox, Canvas, Palette, an edition | `open` and `faces` both become it |
| anything, as a double-click or the explicit control (`.openInCentre`) | `open` and `faces` become it, and a matching `beside` is cleared |

The reading is: **an overview is navigated FROM, while the canvas and an edition are worked IN.** The Book's Cards, Outline and Status (`BookView`) are overviews, so a click on a piece leaves them for the piece. The canvas and an edition are places the writer works, so a click on a piece there changes what the right column is about and leaves the centre alone.

`ClickRule.navigate` is the same rule for a caller outside the tree (a wiki link, a find result, Claude's Show, a board chip, a creation selecting what it made). It differs in one way: a target already beside or last clicked stays where it is (one beside becomes the part clicked last again), because such a caller says "show me this" and never "put it away". Claude's Show opens the canvas and puts away what was beside, so the right column shows the region it selected.

**Going to a place always opens its piece.** A go-to-paragraph or slugline, a translation reveal (a round report row, a publish problem, a figure's Used-in link) and a publish problem with no paragraph set `open` and `faces` to the place's document, whatever the centre was; the reveal is planned against the piece the centre has open, never the faces. Every receiver is named in `ManuscriptForceCensusTests`. A place the window's editor does not yet have loaded is held on `EditorControl.pendingPlace` and landed once that document loads (`ManuscriptNavigation.holdingThePlace`; consumed in `EditorSurface.makeNSView`). It lives on `EditorControl`, `@ObservationIgnored`, and not on `EditorHost`, because it is a request and not control state: nothing may observe it, and a parallel observable on `EditorHost` is tripwire 6. The slot is last-act-wins; `ManuscriptNavigation.openChanged` drops a waiting place whose document is no longer open, and a refused load drops it too, so it never lands on a later, ordinary open.

### The tree

Rows, top to bottom, in `TreeRowSlot` order: the Book; Inbox (only when the project has one), carrying one dot when captures are waiting, never a number; Canvas; the manuscript; Figures (when one is not parked); Research; Palette; Editions (the source language first, labelled Source, then each language that has a translation or a stored translator); then the existing foot (Trash, Removed Elsewhere). Every tree host (`BinderView`, `CollectionPiecesPane`, `SceneNavigatorPane`) draws the same order. Rows select through `List` tags, never `.onTapGesture` (tripwire 9).

Row states as built: the system's selection fill is the row last clicked; the row that is open is tinted; a row that is `faces` but not open, or `beside`, is outlined. The table keeps the clicked row selected, and a note dismissed through the `List` is deselected. Whether the fill belongs on the open row instead is a smoke question and a cheap restyle.

### Lock

`LockToggle` is a toolbar item. `WindowLock.refusesEdits(isLocked:)` is the one answer. Lock is per window, never stored, and every window opens unlocked. It is what the old Review mode's read-only research, palette and figure surfaces became: with Lock on, edits to research, a palette card, a figure and New Table are refused. Lock **does not lock the manuscript text** (that is `EditorControl.isManualReviewMode`, ⌘⌥⇧R, a separate control). Lock **only adds refusals**: each site asks it beside the posture and the share, unchanged and in the same position, so a read-only share, a narrowed book or a piece owned by someone else refuses with Lock off, and Lock off never answers for them.

### Run

Run is four explicit commands in the File menu, each naming its own `RunKind` (`RunCommand`, `Maugham/Compiler/RunKind.swift`): Check Writing ⌘R, Reread ⇧⌘R, Run Round ⌃⌘R, Fresh Eyes ⌃⇧⌘R. ⌘R is a check wherever the writer stands; a round is only ever asked for by name. Nothing infers the kind from the window, so [ADR 0031](0031-the-persona-is-an-input-to-the-run.md)'s two verbs over one substrate stand and its trigger does not.

### The right column

The picker is `DetailSegment.pickerOrder` filtered, never reordered, with one remembered segment in `UIState`. The Department pane is offered only while an edition is open, and a pane that needs a document (and the Annotations pane's document scope) only while the faces' piece is the one the centre has open (`DetailPaneToggle.facesPieceIsOpen`); a segment reached by key or already selected is carried. With the canvas or an edition in the centre the faces can sit on a piece no editor has loaded: those panes show their empty states, and a run there answers with the `.pieceWouldNotOpen` flash rather than doing nothing. At narrow widths the picker falls back from normal to small to a menu; the menu form carries no unread badges. This is transitional: plan 2 replaces the picker.

### What was deleted

`Persona`, `PersonaMemory`, `PersonaBar`, `PersonaModifier`, `RunMenuTitles`, the ⌘1–4 keyspace, `FocusedPersonaKey`, the persona fields of `UIState`, and `DetailSegment.inbox` (the Inbox is a centre subject). The tests that pinned them went with them. `NoPersonaCensusTests` replaces the persona-only greps: no production source names a persona (`\bPersona\b`, `\bpersona\b`).

## Consequences

- One answer to "what is this window about", asked of one value, instead of a mode and a subject that could disagree.
- ADRs 0005, 0025 and 0031 are superseded in part (each carries a line saying which part); their bodies are history.
- A window state file written before this has no `windowSubject`: `UIState` seeds it from the old selection keys and `outlineLayout`, and the persona keys are no longer read.
- Known limits, in this plan: a narrow column hides the picker's unread badges; there is no capture-to-canvas drag within one window (Inbox takes the centre; Send to Canvas remains); every edition shows the same book in preview.

## Not yet built

Later plans of the same milestone. None of these exist; nothing above depends on them.

- To Resolve and the Brief.
- The pulled-up thing and the fold.
- ⌘1–3 (no key is bound to these now).
- Status views beyond the board.
- Per-language preview: every edition shows the same book today.
- Round letters per piece.
- The margin setting and the amendment to [ADR 0027](0027-the-compiler-and-the-editor-boundary.md) §1.
- The rewrite of the guide, the welcome tour and Claude's help text. They still describe personas and ⌘1–4, and the branch does not ship before they are rewritten.
- A drop on the tree's Canvas row as the capture-to-canvas route, with the spec's open decision on the Inbox at scale.
- **The faces' piece readable without the editor** (a store-level read of an unopened piece). Plan 2 is written against it: its To Resolve and Brief show the faces' piece with the canvas in the centre. Until then the document panes are not offered, and a run flashes, for a faces' piece the centre does not have open.
- The tree's stage dot (`ReviewStatus`) and its one "to resolve" dot on rows; only the Inbox dot exists.
- The toolbar's view switch, its language switch on a piece with translations, and its standing running-round indicator; only Lock is built.
- Drop-target feedback on the tree that says which drop is about to happen.
- The old inspector's dispersal: word and page targets to the status line, tags to Outline, links to the fold, publishing settings to the edition's Status; and the line above the prose opening Brief on click.
- An edition's centre scrolling the book to a piece clicked in the tree, and the separate translation-review mode going.
- The Canvas centre's right column (the selected card's or region's details).
- The spec's open decision on what each ⌘⌥ pane shortcut maps to.

## Decisions made during the build

Each was a ruling taken in the build ledger on the agent's authority, not Denver's, unless it says otherwise. Cost-if-wrong is cheap in each.

1. `subjectState` stays `WindowSubject?` (reads as the Book until load), because the research reveal needs the restore to be the first write from nil.
2. Row states stand as built (selection fill is the row last clicked; open tinted; beside and faces outlined).
3. New tree rows select through `List` tags, not `Button(.plain)`.
4. A place that opens an unopened piece lands on its paragraph on the first click: one last-act-wins pending slot on `EditorControl`, reviewed on its own as Task 4b.
5. A find result's 50 ms delay is left alone: that path already lands.
6. The Lock wording in `FigureGridGate` and `FigureGridStrip` is changed with the editor-side fix ("The window is locked — the table can be read, not changed.").
7. The two "is running" lines, which were Denver's verbatim wording of 2026-10-17 and named a persona, are **amended 2026-11-17** and need Denver's choice of words. Diagnostics: "Review's round is running — ⌘R waits until it finishes." became "A round is running — ⌘R waits until it finishes." Cockpit: "Author's check is running — Run waits until it finishes." became "A check is running — Run waits until it finishes."
8. The Inbox row shows one dot when captures are waiting, never a number.
9. Leaving an edition coerces a selected Department pane to the first visible segment.
10. The picker falls back normal, small, menu, with no badges in the menu form (transitional).
11. There is no capture-to-canvas drag in one window; Send to Canvas remains.
12. The word ceiling of `docs/tripwires.md` is raised by 10 for the `NoPersonaCensusTests` line.
13. `NoPersonaCensusTests` greps `\bPersona\b` and `\bpersona\b` only.
14. **Lock does not lock the manuscript text**, a departure from the approved design, which said it would cover "the text and the research and figure surfaces Review locks today". Review locked only research, figures and palette cards, and no existing plain text lock was found to reuse (`isManualReviewMode` is the editor's own control). Cost if wrong: Denver may want the text locked later, a new refusal at the editor's write door.
15. The final fix wave (whole-branch review C1, I1, I2): a reveal and a publish problem are places; `WindowSubject` records which of `faces` and `beside` was clicked last; the document panes and a run ask whether the faces' piece is open (the smallest fix, not the store-level read, which is plan 2's).
