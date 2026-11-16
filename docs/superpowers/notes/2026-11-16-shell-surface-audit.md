# Shell surface audit: what the window shows, and where it would live without personas

*2026-11-16. Working note for the "tree picks the thing, layers show what is attached" exploration. Not a spec. Sources: `Persona.swift`, `DetailSegment.swift`, `CentreRoute.swift`, `BinderSubject.swift`, `Maugham/Views/AREA.md`, `docs/problem-map.md`. Mockups: `.superpowers/brainstorm/` (untracked).*

> **Superseded as a model** by `docs/superpowers/specs/2026-11-16-subject-resolve-brief-shell-design.md`, written later the same day. The three kinds of layer, the Brief tree section, the Info tab and the per-row counts below were all replaced there (two faces, To resolve and Brief; dots, not counts). This note stands as the inventory of what the window shows today.

## The model being tested

- **The tree picks the thing.** The canvas and the editions become tree rows beside the pieces.
- **Layers show what is attached to the thing.**
- **One click rule.** (1) If the centre already contains the clicked thing, find it there. (2) If it is reference material, open it beside. (3) Otherwise it becomes the centre. Double-click always opens in the centre.
- **No behaviour asks which persona is active.**

## Finding: "layer" is three different things

The first mockup put every attachment in one row of toggles. The audit says they split, and only the first kind needs a toggle.

| Kind | What it is | Members | Control |
|---|---|---|---|
| **Marks** | Drawn on the text itself | Notes, Checks, Tasks (already inline as checkboxes) | A toggle each |
| **Beside** | Read next to the text, never drawn on it | Research and pinned references, Cards, Intent, History, Info | Tabs in the right column, always available |
| **Alternate text** | Replaces the text with another rendering of it | Translation (per language) | A language switch on the piece, not a toggle |

Consequence: the toolbar carries a few toggles plus Lock, not a long row. The right column keeps a tab picker much like today's, but with one membership instead of four.

Cost: marks for notes in the editor are not built today (`docs/problem-map.md` lists inline marks as open). This model depends on them.

## Every surface, and its new home

### Things: a tree row that takes the centre

| Today | New home | Fit |
|---|---|---|
| Editor on a piece | Piece row | Clean |
| Screenplay scene (slugline) | Scene row; clause 1 scrolls the open script | Clean, and it confirms the click rule |
| Collection reference piece (placeholder card) | Piece row | Clean |
| Canvas (Plan's centre) | A Canvas row | Clean. Clicking a piece lights its region (clause 1) |
| Corkboard / Outline (project at altitude) | Book row, as two of its views | Clean |
| Review board (pieces × passes) | Book row, as a third view | Clean; see Status below |
| Book preview (Publish's centre) | An edition row, from today's Exports footer | Clean |
| Design gate, translation round report, publish problems, notices | Covers over the edition's centre, as today | Clean; they already outrank the book in a fixed order |
| Palette wall | The Palette section's own row | Workable. Removes the "wall never over Plan's board" rule and the travelling door |

### Reference: a tree row that opens beside

| Today | New home | Fit |
|---|---|---|
| Research item (four placements, by persona) | Beside; double-click for the centre | Clean. One rule replaces four |
| Figure (four placements, by persona) | Beside; double-click for the centre grid | Clean |
| Palette card | Beside | Clean |
| Study column | This *is* the beside slot | Generalises what exists |
| Intent (book), Visual Language, What I've Learned, First Reader, edition brief | A **Brief** section in the tree; each opens beside | Clean. The persona-shell spec §5.0 already parked a left-column home for these as owed |

### Attached to a piece

| Today (right pane) | Kind | Notes |
|---|---|---|
| Annotations | Marks + tab | The round cockpit and pass filter stay in the tab |
| Diagnostics | Marks + tab | See "Run" below |
| Tasks | Marks + tab | See "Tasks and what is waiting" |
| Intent (piece scope) + intent strip | Beside | The strip is the tab's one-line form |
| References (the pinned shelf) | Beside | Merges with the piece's folded research into one Research tab |
| Canvas cards for this piece | Beside | New tab; the data exists (piece association) |
| History | Beside | Rewind stays a sheet |
| Inspector (synopsis, tags, pass ladder, publish overrides) | Beside, as **Info** | Always the last tab |
| Translation | Alternate text | Language switch on the piece; the queries tab appears with it |

### Attached to an edition

| Today | New home |
|---|---|
| Department desk | The edition's main beside tab |
| Translation pane (queries, spot-check) | The edition's, or the piece's when a language is switched on |
| Per-piece publish overrides | Info, on the piece |
| Exports list | The edition rows themselves |

### Inspectors that follow the centre

Region / line / card inspector (canvas), figure inspector, research inspector, piece inspector. All become "Info for whatever is selected". `inspectorRoute` stops asking `centresTheCanvas` and asks what the centre is.

### Unchanged: not shaped by personas today

Tree furniture (Figures, Research, Palette sections, Trash, Removed Elsewhere, Find overlay); posture surfaces and the standing line; banners and pills; ⌘S flash; status footer; rewind, restore, checkpoint, admission, claim and settings sheets; Statistics, Help and Settings windows; the phone.

## Tasks and what is waiting

Three things are easy to conflate:

1. **The writer's own to-dos.** Inline checkboxes at a paragraph, plus project-level tasks in the `__project__` stream.
2. **Things waiting for a decision.** Open notes, translator queries, design proposals, publish problems, phone captures, admission requests.
3. **Where each piece stands.** Draft stage and pass states.

Today these are spread over the Tasks pane, the Annotations pane's This Piece / All Pieces switch, the Inbox pane, the review board, the desk and sheets.

Proposal: **scope follows the subject.**

- On a piece, the Tasks and Notes tabs show that piece's.
- On the Book row, the same tabs show the whole book's, grouped by piece. The This Piece / All Pieces switch disappears; selecting the Book is the switch. Project-level tasks live here.
- Tree rows carry counts (stage dot, open notes, open tasks), so the tree is the at-a-glance answer to "what needs me".
- The review board widens into a **Status** view of the Book: pieces down the side; stage, passes, open notes and open tasks across. This is the one place the old pipeline remains visible, as a property of each piece.

**Inbox is the exception.** A capture belongs to no piece yet, so it cannot be a layer. It becomes its own tree row with a count, and filing a capture is a drag onto the row it belongs to (the classifier for tree drops exists).

Admission requests and load questions stay as sheets: they block, and they are rare.

## Misfits and open decisions

| # | Issue | Options |
|---|---|---|
| 1 | **What Run means.** Today the persona says check or round. | Two explicit commands; or Run follows the frontmost tab (Checks tab runs a check, Notes tab runs a round) |
| 2 | **Review's read-only centre.** | An explicit Lock toggle; possibly on automatically while a round is being worked |
| 3 | **Inline marks for notes** are unbuilt. | Build them (the model needs them), or Notes stays tab-only at first |
| 4 | **Open versus clicked** are now two states in the tree. | Outline and fill (as mocked); or the beside item is shown only in the right column's header |
| 5 | **Right column pressure.** Tabs plus a beside item in a 240–480pt column. | Beside item is itself a tab; icons only, per the existing narrow-toolbar rule |
| 6 | **Double-click discoverability.** | Every beside view carries a visible "open in centre" control |
| 7 | **⌘1–4 muscle memory.** | Keep as presets (subject + toggles), or retire |
| 8 | **Per-persona pane memory** (`PersonaMemory`). | Remember the tab per kind of subject instead |
| 9 | **The four-rooms story** for newcomers and the guide. | Presets carry it; or the Status view does |

## What goes away

- The persona bar and the per-persona pane lists.
- Research and figure placement decided by persona.
- The palette wall's travelling door and the double-click-travels-only-in-Plan rule.
- The This Piece / All Pieces scope switch.
- Force-setting the translation pane from outside its persona.

## Not yet examined

Reports (figures as first-class, the Insert menu gate), the ⌘\ focus and canvas-collapse behaviours, the full ⌘⌥ keyspace, and the cost in tests and censuses (`PersonaPaneRegistryTests`, `CentreRouteTests`, the persona tripwires).
