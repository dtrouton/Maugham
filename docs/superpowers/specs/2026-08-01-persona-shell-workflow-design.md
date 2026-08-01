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

- **Plan** loses outline, tasks and inspector.
- **Author** loses outline and inspector, and gains history.
- **Review** keeps its members but splits them across the two postures.
- **Publish** loses translation, intent and inspector.

Outline leaves every persona: the tree shows structure and Plan now builds it,
and `OutlinePane` is read-only — it renders and sets the selection, but has no
create, move or delete, so it cannot be the structure surface Plan needs.

Publish keeping `.inspector` was a deliberate deviation from §6.3, taken so the
picker was not a single button reading as broken chrome. With visual language and
config there, that reason expires.

**Translation moves to Review only.** `TranslationReviewPane` is source text plus
translator queries — adjudication, not building an edition.

**History joins Author.** It takes `activeDocId` like any per-document pane
(`DetailPaneToggle.swift:404-414`) and works wherever a document is selected; it
is registered only in Review today.

**Posture is Review's alone today, and Author's at M2** — see §2. Plan and
Publish are not waiting to grow one; they do not have two jobs over one object,
which is the only thing posture is for.

### 5.1 Publish is mostly unbuilt, and this records what it needs

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
delete dead panes (outline everywhere; inspector from Plan and Author;
translation from Publish; intent from Publish; history into Author). Removes
`StatementPane`'s pane-local scope switch. Small, mostly registry, and it closes
§1's hole for project scope immediately.

**Slice 2 — Plan's tree.** The manuscript tree as a left segment in Plan with the
canvas staying in the centre, and structure creation reachable from it. This is
the slice that makes Plan able to produce what §2 says it produces.

**Slice 3 — the canvas highlight.** §4's three states, including the offer to
bind. Depends on slice 2.

**Slice 4 — Review's posture.** Columns follow `ReviewPosturePolicy.Effective`.
Nine panes become two sets. Best done alongside or just before M3, which is the
milestone that gives Review its named passes.

**Not scheduled:** Publish's columns, which wait on M4's surfaces; Review's
"pieces by review state" left column, same.

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
