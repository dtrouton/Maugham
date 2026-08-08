# The shell finish — one tree, one width, and the centre that renders the subject

*Brainstormed 2026-08-08 with Denver, from three complaints about the shipped
persona shell. This spec supersedes the LEFT-COLUMN half of
`2026-08-01-persona-shell-workflow-design.md` (the `BinderSegment` picker, the
per-persona segment registries) and amends its right-column §5.0 where named
below. The persona bar, the personas themselves, posture, and the keyspace
principles stand. Slice 7 ("research becomes a view") is **absorbed**: the one
tree plus the canvas are its answer for now; tags and saved views stay out.*

---

## 1. The findings

Denver, with the app in front of him: the right column **shifts width** as
personas change; the left segment strip **shows one tab in most modes**
("rubbish"); Plan's left side has **three tree-shaped tabs showing almost the
same thing**; and the project head-row in Author **does nothing when clicked**
("if we're going to have this it needs to have a function, like shows the
corkboard").

One diagnosis: **the shell multiplied containers where the writer wanted
stability.** Several tree-shaped lists behind tabs, per-pane widths, pickers
rendered with nothing to pick. The finishing move is subtractive.

## 2. The two rules

> **The tree picks the subject. The persona decides how the centre renders
> that subject.**

> **One writer-owned width per column. A picker exists only where a real
> choice exists.**

## 3. The one tree

Every persona shows the same left column:

- **Pieces** — the manuscript structure exactly as today (groups, chapters,
  reorder-by-drag, rename, the head project row). Each piece **unfolds to its
  own research** beneath it (the `ResearchScope` containment truth, finally
  drawn where it lives).
- **Research** — project-wide notes and groups, below Pieces.
- **Palette** — the cards, flat, below Research.

**Selection is the window's one subject**: `BinderSubject` widens from
{project, piece} to {project, piece, research item, palette card}. This
retires the unswept-selection bug class (`selectedResearchId` /
`selectedPaletteCardId` as separate `@State`) recorded since the shell
slices — one subject, one sweep, one validation.

**Drag is scope.** Dragging a note between a piece's fold and the shared
Research section is the existing scope move (`ResearchMoveTarget`) given its
obvious gesture. Nothing new is invented; a shipped store API gets its
surface.

**Transients stop being segments.** Find is an overlay state of the tree
(results replace it while active; Esc restores — the same posture the canvas
dim uses: deliberately entered, deliberately left). Trash is a disclosure at
the tree's foot, present only when non-empty. The **segment strip ceases to
render** — there is no picker because there is no choice.

**Deferred, recorded**: folding screenplay sluglines into the tree (the
Scenes navigator stays as-is this pass); tags/saved views over research.

## 4. The centre renders the subject

| Subject → | Plan | Author | Review | Publish |
|---|---|---|---|---|
| **The project** | whole canvas, undimmed *(shipped)* | **corkboard / outline**, full width | read-through overview *(M3's queue later)* | whole-book preview |
| **A piece** | canvas dimmed to its bindings *(shipped)* | the prose editor *(shipped)* | read-mostly editor *(shipped)* | that piece's preview |
| **A research note** | its card highlighted on the board; preview in the right column | the research editor | reference view (read-only preview) | — (project altitude shown) |
| **A palette card** | highlighted likewise | the card editor | read-only card | — |

**Project altitude is the dead row's function.** Clicking the project in
Author shows the manuscript at book altitude — the corkboard/outline, moved
from the right pane to the centre, full width, with its existing
layout toggle (cards ↔ table) as a centre-local control. Click a card → that
chapter opens. The clunky no-op becomes *zoom out*.

**Plan's centre is the canvas, always.** The Structure-tab route to an editor
inside Plan is gone. Getting into prose from Plan is deliberate travel:
**double-click a piece → Author with that piece open** (one gesture; the
subject carries). This is the persona identity working — Plan is the persona
that doesn't draft — argued against must #2 in §8.

**Review/Publish degrade gracefully**: subjects they have no rendering for
(a palette card in Publish) show the project-altitude view rather than a
blank — the centre never renders nothing.

## 5. The right column — steadied and thinned

**One width.** The window has one writer-owned right-column width, persisted
in ui-state, dragged at the divider; every pane conforms; switching personas
or panes never moves it. (The assistant column's width is separately owned,
already, and the column is Author-only by Denver's 2026-08-08 ruling.)

**The registry thins**, because the tree and centre absorbed real work:

- **Outline and Corkboard leave the registry everywhere** — they are the
  project-altitude centre now.
- **Author's Research and Palette panes leave** — the tree opens those things
  in the centre; beside-the-prose reference is References + the assistant
  column's job. (Plan's right-column preview of a selected research item —
  §4's cell — is the existing preview surface mounted as the persona's
  rendering of that subject, not a registry pane.)
- Everything else stays per its persona's registry; `PersonaPaneRegistryTests`'
  canonical order updates once.

**The keyspace keeps its promises.** ⌘⌥-letter shortcuts whose panes die
re-point rather than dying — muscle memory is sacred (⌘S's own rule):
**⌘⌥R focuses the tree's Research section; ⌘⌥P focuses Palette; ⌘⌥O selects
the project row** (the outline's new home). Each shortcut still lands the
writer on the thing the letter always meant; a retrain of location, not of
meaning. `docs/guide/reference.md` updates in the same commit as each
re-point (the Toggle-Review-Mode lesson).

## 6. What dies, named

- The `BinderSegment` **picker** and the per-persona `binderSegments(for:)`
  registry. The enum itself survives only if the transient states (find,
  trash) still want a spelling — implementation may collapse it to a
  `TreeOverlay` enum; either way **the no-default exhaustive-switch
  discipline carries** to whatever replaces it.
- `Persona.binderHome(for:)` and the segment-restore machinery in
  `applyPersonaChange` (per-persona segment memory has nothing to remember).
- The right-pane `OutlinePane`/`CorkboardPane` registrations and Author's
  `ResearchPane`/`PalettePane` registrations (the views survive where the
  centre reuses them).
- The width-per-pane behavior, wherever it lives.

## 7. Relationship to prior work

- The subject-picker (slices 1–2) and the canvas highlight (slice 3) are the
  foundation this stands on — the tree was already the window's
  subject-picker; it now speaks three more id spaces and loses its rivals.
- The parked Inspector dissolution (old slices 4+5) stays parked; `.inspector`
  is untouched by this spec.
- The M2/second-draft surfaces (Diagnostics, Intent strata, References) are
  untouched except for the width rule they now obey.

## 8. Constitution check

- **Lenses, not gates.** Plan's canvas-always centre does not gate drafting:
  every piece remains one double-click from its editor, and no capability is
  removed — relocated gestures, not permissions. The strip's death removes
  chrome, not access (Find/Trash keep their commands and keys).
- **Muscle memory** (§5): every retrained shortcut lands on the same *meaning*.
- **Nothing pushed**: the tree offers no nags; the project row's altitude view
  renders content the writer already owns.
- **Plain text / op log**: untouched — this is window furniture.

## 9. Sequencing — one milestone, three stages

1. **The width and the strip** — the two mechanical fixes (one right-column
   width; the picker renders nothing when choiceless — an interim rule that
   the full tree then makes permanent). Small, immediately felt.
2. **The tree** — sections, nesting, widened `BinderSubject` + the one sweep,
   drag-rescope, find/trash as transients, the strip's true death.
3. **The centre rule** — project altitude (corkboard moves), per-persona
   subject rendering, the Plan double-click hop, registry thinning + keyspace
   re-points + docs.

Whole-branch review per stage; merged unpushed like everything since M1A;
Denver's smoke closes it.

## 10. Out of scope

- Screenplay scenes in the tree; tags/saved views over research (slice 7's
  remainder, revisit after living with the tree).
- The Inspector dissolution; M3's Review queue.
- Any phone surface.
