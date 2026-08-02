# The persona shell — what each mode is for, and what its columns owe it

*Design, 2026-08-01. An amendment in force to §6.3 and §8 of
`2026-07-25-mode-based-ux-redesign-design.md` (**the umbrella spec**), written
after M1A shipped and exposed a hole. Where this and the umbrella spec disagree
about the pane × persona matrix, this document is later and wins; everywhere
else the umbrella spec stands.*

---

## 1. What prompted it

M1A gave the Plan persona an Intent pane. Intent is scoped to the project **or a
manuscript document**, and it resolves that scope from `selectedItemId`
(`ProjectWindow.swift:1222` → `DetailPaneToggle` → `StatementPane.effectiveScope`).

**Plan's left column cannot select a manuscript document.** It offers
`[.canvas, .research, .palette]`, and the manuscript segment was deliberately
withheld: the coercion rule keeps whatever segment the destination offers, so a
writer entering Plan from the manuscript would land on the manuscript and never
see the planning surfaces.

So Plan's Intent pane derives its subject from a selection the persona neither
displays nor lets you change — inherited from whichever persona you were in
last, since `applyPersonaChange` (`ProjectWindow.swift:1972`) records and
restores per-persona positions but never touches `selectedItemId`.

Pulling that thread found four more things, and they are one problem.

---

## 2. Stage, centre, and the one place posture is real

**Persona is the stage — what you are producing.**

| Persona | Output |
|---|---|
| Plan | intent, visual language, promoted artifacts, **and the manuscript's structure** |
| Author | draft |
| Review | adjudicated notes |
| Publish | editions |

Plan producing *structure* is new here and is the writer's own account: *"I'm
producing the intent and the structure in this mode… I don't need to see
anything written in the manuscript but I need the structure and the ability to
create the structure."*

**Posture is whether you are making or responding**, and it already exists in the
codebase, unused by the shell. `ReviewPosturePolicy.effective(role:manualReview:)`
(`ProjectWindow.swift:406-409`) fuses `CollaborationRole`
(`MaughamCore/CollaborationRole.swift:15-19` — `author`, `reviewer`, `unknown`)
with the manual ⌘⌥R toggle, and produces `isReviewMode` + `lockEditing`, with the
role as a hard floor so the toggle can never unlock someone else's text. Today it
drives only the editor's render and lock.

**Posture is not universal, and an earlier draft of this document was wrong to
say it was.** It is needed exactly where two different jobs are done *over the
same object*, so nothing else can tell them apart:

- **Review** — producing notes and adjudicating notes both happen over the same
  prose. *"It's both I'm reviewing and I'm responding to review."*
- **Author, at M2** — writing and answering diagnostics both happen over the same
  paragraph.

**Plan and Publish do not have a posture.** In Plan the two things you might be
doing are distinguished by *what you are looking at*, which the left segment
already selects — and the right column stays the same beside either, because a
capture can become a research note or go to the canvas, and reading research is
exactly when intent changes. That is not a posture; it is a persona with more
than one centre.

So the rule is narrower than "two axes":

> **Persona is the stage. The left segment selects the centre. The right column
> belongs to the persona — except in Review, where the columns follow the
> posture.**

**A pane belongs to a persona if it serves that persona's output.** In Review,
and only there, it belongs to a posture within it if it serves producing or
adjudicating specifically — history serves adjudicating (what changed) and not
producing; the queue-shaped reading of annotations serves adjudicating and not
writing a note.

**This is what closes the third case.** Reviewing *someone else's* work is not a
mode — it is `role: .reviewer`, which forces the posture, which sets the columns.
Reading your own draft cold is ⌘⌥R, which does the same thing by choice.
Adjudicating is the absence of both. Three activities, one mechanism, no new key.

---

## 3. The tree is the window's subject-picker

### 3.1 The centre column follows the left segment; the tree's meaning follows the persona

| Left segment | Centre column |
|---|---|
| **Tree** (the manuscript) | **Plan → the canvas · Author → the editor** |
| Research | the research note |
| Palette | the palette card |

Research and palette are the same object at every stage, so their centre never
varies. The manuscript is the one thing whose *meaning* changes by stage — in
Author it is text you write, in Plan it is a shape you are arranging — so it is
the only row where the persona decides.

Half of this already holds: `.canvas` and `.research` **share one left pane**
(`BinderPaneToggle.swift:31` renders `ResearchView` for both), and only the
centre differs. What is missing is the manuscript tree in Plan, with the canvas
staying in the centre.

### 3.1.1 Why Plan carries three segments that look like two

With the tree added, Plan's left picker offers `canvas`, `tree`, `research` and
`palette` — and `canvas` and `research` render the *same* left pane. That reads
as redundant and is not.

| Segment | Left pane | Centre | What it is for |
|---|---|---|---|
| `canvas` | research tree | the canvas | dragging a research row onto the canvas (§8A.1's route, 1C-d) |
| `tree` | manuscript tree | the canvas | shaping the structure; lighting what is bound to a piece |
| `research` | research tree | the research note | reading and editing the note itself |

So `canvas` and `research` differ only by centre — which is precisely the writer's
*"if I flip to research in Plan it can replace the canvas with the editor view"*,
and it already works that way today. The drag-in route needs the research tree
**beside** the canvas, so collapsing `canvas` into `research` would break it.

**The picker labels must carry that distinction**, because the left pane will not:
two adjacent segments showing an identical tree, one of which swaps the centre, is
only legible if the label says which. This is the one place in this design where
the naming does real work rather than describing.

### 3.2 The tree drives both other columns at once

- **The right pane gets its subject.** Select chapter 3 and Intent shows chapter
  3's intent. This is §1's hole, closed at the cause rather than at the pane.
- **The centre, in Plan, shows what is bound to it** — see §4.

### 3.3 The project row

**There is no way to select the project.** `selectedItemId = nil` occurs at
exactly one site, `BinderView.swift:193`, inside the delete path — it clears the
selection when the selected item is deleted. There is no project row and no
deselect gesture. Once a chapter is clicked, the window is on a chapter until
that chapter is deleted.

The tree gains a **project row** at its head, naming the project. Selecting it is
how a project-scoped surface gets its subject.

**This deletes a workaround rather than adding a feature.** `StatementPane`
carries its own `[Chapter | Project]` picker *only because the tree cannot say
"the project"*. That pane-local scope concept is what the reverted
`Open`-sets-scope work kept colliding with (M1A Task 7, three fix rounds and a
revert by ruling): two controls owning "what is this pane about", neither of them
the tree. With a project row, the tree is the single subject-picker for the
window, every project-scoped surface asks the same control the same question, and
the pane-local switch is removed.

**Amendment, 2026-08-02 (slice 1 whole-branch review, Critical).** *"The tree"*
is three views, not one, and the slice shipped the row in two of them. A project
type's manuscript home is `BinderSegment.documentHome(for:)`: `BinderView` for a
novel or short story, `CollectionPiecesPane` for a Collection, and — because no
persona offers a screenplay the `.manuscript` segment — `SceneNavigatorPane` for
a screenplay. With the pane-local switch removed in the same slice, the missing
third row made project-scope Intent **unreachable** in a screenplay, and the
adoption path (`legacyCraftIntentByScope`, gated on schema version and never on
project type) can put a writer's own pre-M1A prose in exactly that scope. The
navigator is the odd one of the three: a screenplay is one file, so its slugline
rows are navigation rather than subjects — see `SceneNavigatorPane` for how a
click on a slugline is kept from writing `nil` through the selection.
`ProjectSubjectReachabilityTests` is the census that asks the question of every
project type rather than of a view.

**Second amendment, 2026-08-02 (slice 1 smoke).** The row above the sluglines was
not enough on its own, and adding it *alone* made a new screenplay worse: with
the project selected the centre column blanks, and the escape the navigator was
built with is a *scene* click, which does not exist until the writer has typed a
slugline — which they cannot do, because the editor is not on screen. A new
screenplay was a one-way door.

The fix is not a special case, it is the shape the navigator should always have
had: **a row for the script itself**, between the project row and the sluglines.
A screenplay's binder then reads like every other binder — the project, then the
project's documents — with sluglines as detail beneath its one document, and
because a screenplay always has exactly one script the escape can never be
missing the way a scene row can. It was the only binder in the app that listed
the *insides* of a document and never the document. The selection projection now
accepts two values (`.project` and the script's `.item(id)`) and still ignores
the `nil` an untagged slugline row writes.

*Still left open by ruling:* what the centre column should show when the subject
is the project. It is blank today in every project type; the screenplay is not
made special here.

*Left open by ruling, not by omission:* whether a one-file screenplay should have
a document intent AND a project intent at all is a design question, and this
amendment does not answer it. `StatementPane.effectiveScope` is untouched.

---

## 4. What the canvas does when the tree selection changes

Plan's tree is not a navigator that refuses to navigate. Selecting in it has a
visible effect in the centre column.

| Tree selection | Canvas |
|---|---|
| **The project** | Everything, undimmed. The whole board. |
| **A chapter with bindings** | Its bound regions and their resident cards lit; everything else dimmed. |
| **A chapter with nothing bound** | All dimmed, and the canvas offers the next move: sweep a region and it binds to that chapter. |

The set that lights is **`RegionBinding.references(forPiece:)`** — regions whose
`boundPieceID` matches, unioned, residents only. A card merely *visiting* a
region's rectangle is cited, not owned. That projection had **zero production
callers** from 1C-b until M1A Task 10 gave it one in `list_canvas`; this makes it
visible in the app rather than only over MCP, and makes the umbrella spec's §8
bridge — *"what you cluster around a piece becomes what is pinned beside you"* —
something the writer can see.

**The project row is the way out of the dim**, which is what keeps the dim from
being too loud for a browsing gesture: it is a state you deliberately enter and
deliberately leave, not a flash on every click.

**The offer to bind appears only in the third row** — the state where a dim would
otherwise read as a dead end. It must be refusable without nagging (constitution:
nothing is pushed).

---

## 5. The columns

**R** = a registry line. **B** = something has to be built.

| | Left | Centre | Right |
|---|---|---|---|
| **Plan** | canvas, **tree** (B), research, palette | canvas · canvas · the note · the card | intent, visual language, inbox, research (R) |
| **Author** | binder, research, palette | the editor · the note · the card | intent, research, palette, tasks, **history** (R) |
| **Publish** | editions (B; the Exports footer stands in) | **the compiled page** (B) | visual language, config (B) |

**Review is the one persona whose right column follows the posture:**

| Review posture | Right |
|---|---|
| **Producing notes** (⌘⌥R, or `role: .reviewer`) | the prose, intent, palette, annotations-as-writing (R) |
| **Adjudicating** | annotations queue, history, intent, tasks, translation (R) |

Its left column is §6.3's "pieces by review state", unbuilt; the binder stands in.

**Plan's right column is constant across its four segments** — that is the point.
A capture in the inbox may become a research note *or* go straight to the canvas
(`InboxStore.sendToCanvas` already exists), and reading research is exactly when
intent changes. The Research pane earns its place there for the first time
because the tree now selects a chapter, so "this chapter's own and linked
research" finally has a subject in Plan.

**Leaving**, by persona rather than a count, since the set will move:

- **Plan** loses outline and tasks.
- **Author** loses outline, and gains history.
- **Review** keeps its members but splits them across the two postures.
- **Publish** loses translation, intent and inspector.

Outline leaves every persona: the tree shows structure and Plan now builds it,
and `OutlinePane` is read-only — it renders and sets the selection, but has no
create, move or delete, so it cannot be the structure surface Plan needs.

> **Amendment, 2026-08-01 — this section states its content twice and the two
> disagree; the delta list above is the normative one.** Found by slice 1's
> implementer while transcribing the matrix into
> `PersonaPaneRegistryTests`, which is the test that has to pick one.
>
> The three-column **table** omits cells the **"Leaving, by persona"** list keeps:
> it drops **palette from Plan**, and it drops **visual language from Review**
> (neither posture row carries it). The list says Plan loses only outline and
> tasks, and says outright that *"Review keeps its members but splits them across
> the two postures"* — which the table contradicts directly. Nothing anywhere in
> this document argues for removing either pane, so the table is a summary that
> lost cells, not a narrower claim.
>
> Read the table as illustrative and the delta list as binding. **Inspector is not
> one of these discrepancies** — its absence from the table is §5.1 working as
> intended, and it leaves at slice 4 rather than now.
>
> This does not touch slice 1, whose four moves are the same under either
> reading. It is **slice 6** that has to be right about Review's visual language,
> and slice 6 should confirm this with Denver rather than inherit it.

**`.inspector` leaves every persona, but not by being deleted** — it dissolves,
and its sections go where they are used (§5.1). Publish loses it only once the
Publishing section has become Publish's own pane; until then, removing it deletes
the writer's table-of-contents control.

**Translation moves to Review only.** `TranslationReviewPane` is source text plus
translator queries — adjudication, not building an edition.

**History joins Author.** It takes `activeDocId` like any per-document pane
(`DetailPaneToggle.swift:404-414`) and works wherever a document is selected; it
is registered only in Review today.

**Posture is Review's alone today, and Author's at M2** — see §2. Plan and
Publish are not waiting to grow one; they do not have two jobs over one object,
which is the only thing posture is for.

### 5.1 The Inspector dissolves

The Inspector is the one pane the rule in §2 does not explain. Every other pane
serves a persona's output; the Inspector serves *whatever document is selected*,
and is a stack of unrelated per-document fields. Author wants the word target.
Publish wants the publishing section. Plan wants the synopsis. Nobody wants all
of it.

**It is dissolved and its sections distributed.** Verified contents of
`InspectorView.swift` on 2026-08-01:

| Section | Goes to | Why |
|---|---|---|
| **Status** (draft / revising / final) | **Review** | This *is* "pieces by review state" — §6.3's left column, unbuilt since the umbrella spec. The field it needs has been three sections down a metadata drawer the whole time. |
| **Publishing** (`InspectorPublishSection`: include in ToC, start-on, title override) | **Publish**, as its own pane | The only UI in the app for per-piece publish config; everything else in `PublishConfig.SectionConfig` is MCP-only. |
| **Word target**, **page target** | **Author** | Drafting goals. |
| **Synopsis** | folds into intent — see §5.2 | |
| **Tags** | **Plan** | Organisational. |
| **Links** (`InspectorLinksSection`) | the **Research pane** | It is wiki links to other *documents*; the Research pane already shows a document's own and linked research. One pane for everything this chapter points at. |
| **Words** (count) | nowhere | Already in the editor footer (`EditorStatusFooter`). Duplicate. |
| **Intent affordance row** | nowhere | Added in M1A as a way to reach intent *because the tree could not aim it*. The tree and the Intent pane replace it. |
| **Title** (read-only) | nowhere | The tree says it. |
| **Project Settings…** | nowhere | A button that opens a window; it belongs to the menu. |

**`PieceInspector` is in scope too** — it carries a synopsis section for collection
pieces and is the same shape of drawer.

**This is mostly moving fields into panes that exist or are already planned.**
Only Publishing needs a surface of its own, and that surface is already on M4's
list as "editions and config as a real surface" — this delivers its per-piece
half early.

**Recorded so it is not repeated:** `Persona.swift`'s comment justifies keeping
Inspector in Publish as *"without it the picker is a single button, which reads
as broken chrome"* — a cosmetic reason for a pane that is in fact carrying the
work. An earlier draft of this document proposed removing it on the strength of
that comment, which would have deleted the writer's table-of-contents control. A
comment that states a weaker reason than the real one is how a later reader acts
on the weaker one.

### 5.2 Synopsis folds into intent

Synopsis is what the chapter *is*; per-document intent is what you are *going
for*. They are adjacent enough to be one field, and M1A built the op-logged one
with history while synopsis remains plain manifest metadata that nothing
versions.

**Every reader of `StructureItem.synopsis`, verified 2026-08-01:**

- `InspectorView` (edits it) and `PieceInspector` — both dissolving anyway.
- **`get_outline`** (`MCP/Tools/ProjectTools.swift`) — returns it to Claude, and
  its description names it. This is the only consumer that outlives the
  dissolution: it either drops the field or reads the intent's opening line.
  Either way it is a shape change to a shipped MCP tool.
- `ProjectStore+CollectionPieces.swift` — carried on piece promotion, cleared on
  convert-to-reference.
- `ProjectStore+Metadata.swift` — the setter.

**The trap:** `.synopsis` also appears in `ReferenceTools`, `FountainNodeMapper`
and `TranslationCoverage`. That is the **Fountain element type** (`= synopsis`
lines in a screenplay), not `StructureItem.synopsis`. An over-eager grep will eat
it.

**Existing synopses must migrate into each document's intent**, in the shape M1A's
adoption already established: content arrives as a bootstrap op through
`Document.load`, so it has history from the migration forward rather than none.

### 5.3 Publish is mostly unbuilt, and this records what it needs

The writer's account: *"I'm reviewing the output drafts. I'm also maybe editing
the visual identity for the published page… I'm also sometimes tweaking
formatting when it doesn't look right on the page."*

- **Reviewing the output happens outside Maugham.** `ExportsListView`
  (`Maugham/Views/Publish/ExportsListView.swift`) is a footer on the binder's
  manuscript/pieces segment, and clicking an entry calls `NSWorkspace.shared.open`
  — the book opens in Preview.app.
- **Tweaking formatting has no surface.** Per-piece style and publish config are
  MCP tools only.

Both are M4's "editions and config as a real surface". This document does not
design them; it records that Publish's columns cannot be judged until they exist,
and that the binder's Exports footer is the only piece of Publish's actual work
currently in the window.

---

## 6. Delivery slices

The parts justify each other, so the reasoning stays in one document; the
delivery does not.

**Slice 1 — the subject-picker.** The project row, and the registry moves that
delete dead panes (outline everywhere; translation and intent from Publish;
history into Author). Removes `StatementPane`'s pane-local scope switch. Small,
mostly registry, and it closes §1's hole for project scope immediately.

**Slice 2 — Plan's tree.** The manuscript tree as a left segment in Plan with the
canvas staying in the centre, and structure creation reachable from it. This is
the slice that makes Plan able to produce what §2 says it produces.

**Slice 3 — the canvas highlight.** §4's three states, including the offer to
bind. Depends on slice 2.

> **Open question for slice 2, raised 2026-08-02 during slice 1's smoke: what
> does a persona's CENTRE show when the subject is the project?**
>
> Denver, on hitting it in Author: *"the middle pane being select a document is
> kind of annoying anyway — I'd been wondering if this should be an outline
> view."*
>
> **Plan already has an answer and it is §4**: the project row shows the whole
> board, undimmed. Author has no answer — it shows the `EditorHost` placeholder,
> which is a true statement and an empty screen. The question is whether the
> project subject should mean *"here is the whole thing"* in every persona rather
> than only on the canvas, and an outline is the obvious candidate for Author.
>
> It belongs to slice 2 because slice 2 is already deciding what the centre does
> as the tree's selection changes, and answering it twice would be how the two
> answers drift. Note the pull the other way: `OutlinePane` is read-only and
> §5 removed it from every persona's picker precisely because it cannot be the
> structure surface Plan needs — so *"put the outline in the centre"* is not a
> free reuse of an existing pane, and should be argued rather than assumed.
>
> **Not a blocker for slice 1.** The placeholder is pre-existing behaviour; the
> project row only made it reachable more often.
>
> **A screenplay is the case that will judge the answer** (Denver, 2026-08-02,
> on the shipped fix): *"we will need to come back to script and project being
> two lines for screenplay — it's weird right now, but if we bring in outline at
> project in the centre this might be much better."*
>
> Two header rows in a pane whose whole content is one document reads as
> redundant, and it is **the centre that makes it redundant**: selecting either
> row currently produces a blank or the script, so the pair looks like two names
> for one thing. Give the project subject a centre of its own and they stop
> being two names — one shows you the shape of the project, the other opens the
> script. So the two-row shape is **provisional and deliberately not re-cut
> now**: it is the honest fix for a trap (a screenplay had no way back off the
> project row), and re-cutting it before the centre is decided would be
> designing the header against a placeholder.

**Slice 4 — the Inspector dissolves** (§5.1). Each section to its persona, and
the Publishing section becomes Publish's own pane. **Do not start this before
slice 1**: the Intent affordance row only goes away once the tree can aim, and
the publishing pane is the thing that lets Inspector leave Publish without
deleting a control.

**Slice 5 — synopsis folds into intent** (§5.2). A migration plus a `get_outline`
shape change. Independent of the shell slices; depends on nothing but M1A.

**Slice 6 — Review's posture.** Columns follow `ReviewPosturePolicy.Effective`,
and its left column becomes "pieces by review state" using the status field slice
4 freed. Best done alongside or just before M3, the milestone that gives Review
its named passes.

**Slice 7 — research becomes a view rather than a folder tree.** Denver's
addition, 2026-08-02, **deliberately left unspecced until slices 1–6 have
landed** — it is the largest idea in this document and the least constrained by
what already exists, so specifying it against a shell still being reshaped is
the mistake CLAUDE.md rule 11 exists to prevent.

What prompted it, in the writer's words: *"selecting a piece or chapter to then
go to research to have that filter is wonky… I just want to organise my
thinking."* And the framing that resolved it: **this is the difference between
tags and folders**, and the writer does not care where a note lives on disk.

The thread to pick up, so it is not re-derived:

- **The shape.** One tree in Plan, always present, whose spine is the
  manuscript's hierarchy and whose leaves are each piece's *material*. Not a
  second copy of the filesystem — a **view over relationships**, so dragging in
  it edits the relationship and never the file.
- **The objection that shape survives, and the one it must still answer.**
  `ResearchScope` routes three different ways — a Collection loose piece gets
  real containment (`pieceFolder`), a novel chapter gets **shared research plus
  a `linkedResearchIds` link**, and a short story or screenplay gets
  `sharedOnly` with no per-document notion at all. A tree that renders *link* as
  *containment* is the membership-from-geometry error tripwire 31 exists for,
  arriving in a new place. Calling it a view rather than storage answers that —
  a note linked to two chapters appearing under both is correct for a tag and a
  lie for a folder. What it does **not** yet answer: **unlink must be
  distinguishable from delete** (the canvas region inspector's minus — *"takes a
  card out of a region; the card itself stays"* — is the precedent to copy), and
  **research belonging to no piece still needs somewhere to be**, or it becomes
  unreachable in the view that replaced the one it was found in.
- **Sequencing.** After slices 1–6, and specced then rather than now.

**Not scheduled:** the rest of Publish's columns, which wait on M4's surfaces.

### 6.1 The left column is not a lens — a correction to §8

*Recorded 2026-08-02, verified against the tree the same day.*

**There is no keyboard route to a `BinderSegment`.** Every right-hand pane has a
`⌘⌥`-letter in `MaughamApp`'s View menu; the left column has nothing. So the two
registries fail differently and §8's *"personas are lenses, never gates"* is true
of one of them:

- Dropping a pane from `Persona.panes` is a **demotion**. `⌘⌥O` still opens
  Outline in every persona (slice 1 proved this, and replaced a test that
  asserted the opposite).
- Dropping a segment from `Persona.binderSegments(for:)` is a **removal**. The
  only route back is switching persona.

**Consequence, decided 2026-08-02: research leaves the LEFT column of Author,
Review and Publish, and that is a removal made deliberately.** The argument is
not convenience — it is that **the right-hand registry already says research is
not Review's or Publish's business** (`.research` is a pane in Plan and Author
and absent from both the others), so the left column was the half that
disagreed. Editing research is making planning material, which is Plan's output
under §2's rule, and Author keeps `LinkedResearchPane` on the right for reading
what a chapter points at.

Two things this costs, both stated rather than discovered:

- **Review and Publish drop to a one-segment left picker** — the *"reads as
  broken chrome"* shape already argued at `Persona.swift`'s Publish case. Judged
  acceptable because both of those columns are **already** deviations standing in
  for unbuilt surfaces (§6.3's "pieces by review state" and "editions"), so the
  single entry makes a placeholder visible rather than disguising it, and M3/M4
  each supply a real second entry. Padding a picker with a segment that does not
  serve the persona is what slice 1 refused to do for `.outline`.
- **Editing a note mid-draft becomes a persona switch.** Author's research pane
  is a *preview*. The writer judges the hop acceptable; it is the first thing to
  check in smoke, not something to settle in the abstract.

**`selectedResearchId` is `@State` on `ProjectWindow`, not in `UIState`** — so
the hop keeps your place within a session and loses it on quit. One field if
that turns out to matter.

**Sequencing against M1A:** none of this starts until M1A has been smoked and
its milestone is closed. Slice 4 and slice 5 both touch things M1A shipped —
`IntentAffordanceRow` and per-document intent — so they want a settled base
rather than a moving one.

---

## 7. What was read out of the tree on 2026-08-01

Everything below was verified the day this was written. Anything not here is a
claim to check, not a fact.

- `Persona.panes` and `Persona.binderSegments(for:)` — the current lists, in
  `Maugham/Models/Persona.swift`.
- `StatementPane.effectiveScope(kind:activeDocumentId:structure:prefersProjectScope:)`
  — resolves `.document` only for a `type == .document` structure item.
- `ProjectWindow.swift:1222` passes `activeManuscriptItemId: selectedItemId`.
- `DetailPaneToggle.segmentContent` is exhaustive over `DetailSegment` with no
  `default`, so a new pane cannot ship unrouted.
- `BinderView.swift:132` is the **only** call site of `addStructureItem`.
- `OutlinePane` has no create, move or delete.
- `BinderPaneToggle.swift:31` renders `ResearchView` for **both** `.research` and
  `.canvas`.
- `existingEditorSwitch` sends `.manuscript`/`.scenes`/`.find` to `EditorHost`
  and `.canvas` to `CanvasView`.
- `applyPersonaChange` (`ProjectWindow.swift:1972`) records and restores
  per-persona binder and detail segments; it does not touch `selectedItemId`.
- `CollaborationRole` is `author | reviewer | unknown`
  (`MaughamCore/CollaborationRole.swift:15-19`).
- `ReviewPosturePolicy.effective(role:manualReview:)` (`ProjectWindow.swift:406-409`),
  `lockEditing` a hard floor.
- `historyPane` takes `activeDocId` (`DetailPaneToggle.swift:404-414`).
- `ExportsListView` opens entries with `NSWorkspace.shared.open`
  (`Maugham/Views/Publish/ExportsListView.swift:43`).
- `selectedItemId = nil` occurs once, in the delete path
  (`BinderView.swift:193`).
- `.references` remains reserved for M2 in `Persona.swift`; `grep -rn "case
  references" Maugham/` returns nothing.

---

## 8. Constitutional check

- **Personas are lenses, never gates** — unchanged. Every pane stays reachable by
  its `⌘⌥` shortcut regardless of persona; the registry sets what the picker
  offers and in what order. A posture-dependent column set is still a lens.
- **Nothing is pushed** — the offer to bind (§4) must be refusable and must not
  recur as a nag.
- **The writer's method is not imposed** — the tree's project row and the dim are
  navigation, not process. Nothing here requires a binding to exist before
  writing.
