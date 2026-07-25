# ADR 0025 — Persona shell: four optional lenses over one project

**Date:** 2026-07-25 · **Status:** Accepted · **Milestone:** persona-shell (branch `feat/persona-shell-2026-07-25`)

## Context

By mid-2026 the right pane had grown to nine undifferentiated modes (Inspector,
Annotations, Research, Outline, History, Tasks, Inbox, Palette, Translation) behind one
flat `⌘⌥1–8` numeric keyspace plus `⌘⌥A`. Palette had to wedge in at `⌘⌥7` and
Translation took the last slot, `⌘⌥8` — the space was full, and this milestone's design
(`docs/superpowers/specs/2026-07-25-mode-based-ux-redesign-design.md` §6) called for five
more panes on the drawing board (Diagnostics, References, Intent, Visual language,
Editions & publish config). There was nowhere left to put them, and every mode was
offered to every writer regardless of what they were doing — a planning-stage writer saw
Annotations; a reviewing writer saw the Inbox.

The natural fix — grouping panes by what stage of work a writer is in — runs directly
into `docs/constitution.md`'s must #2, **"Maugham imposes no method… never requires a
workflow, an outline, or a daily quota."** Any design that reads as "finish planning
before you're allowed to draft" is dead on arrival against that principle. The question
this ADR answers is how to get stage-appropriate panes without building a gate.

## Decision

### 1. Four personas — Plan, Author, Review, Publish — are optional lenses, not gates.

`Persona` (`Maugham/Models/Persona.swift`) is a four-case enum selected by `⌘1`–`⌘4` from
a bar in the window toolbar. Switching persona changes which panes are *offered* in
the left-column binder and the right-column detail picker (via `binderSegments(for:)` and
`panes`) and which one is *selected first* — it does not disable, hide, or require
anything. Every persona is reachable at any time, on any project, in any state:

- There is no threshold a project must cross to unlock a persona. A brand-new,
  empty project opens every persona exactly as a manuscript deep into revision does.
- There is no ceremony to enter or leave one. `⌘1`–`⌘4` is a single keystroke, symmetric
  in both directions, with no confirmation and no unwind cost.
- A forced navigation (a wiki-link jump, an MCP note banner, a task click) always lands
  on the segment it targets regardless of the active persona — `Persona.coerce(_:)` only
  ever redirects a segment the writer *picked* that the destination persona doesn't
  offer; it never blocks a segment something else in the app already decided to show.
- Author remains `Persona.default`. An upgrading writer who never touches the bar sees
  no change: today's three-pane layout, today's shortcuts (mapped 1:1, see §2).

**This is recorded explicitly because the pressure to tighten it will arrive later** —
"you should really finish planning before you draft," or "lock Publish until Review is
clean," are the kind of feature requests that read as helpful and are the kind of
decision this ADR forecloses. Personas are a *view* over one project, chosen the way a
writer chooses which tool to pick up next, never a state machine with required
transitions. If a future proposal wants a persona to gate something, that proposal
conflicts with constitution must #2 directly and needs to win that argument on its own
terms — it does not get to cite this milestone as precedent, because this milestone
chose the opposite on purpose.

Two deviations from the design's own §6.3 pane/persona matrix are recorded at the call
site in `Persona.swift`, not hidden: Publish carries `.inspector` though §6.3 marks it
`—` (a single-button picker reads as broken chrome, not restraint), and Review's/
Publish's left column stands in with the ordinary binder because "pieces by review
state" and "editions" don't exist yet. Both are marked `DELIBERATE DEVIATION` inline and
are expected to unwind as later milestones build the surfaces §6.3 actually specifies.

### 2. The pane registry is the extension point.

`Persona.panes: [DetailSegment]` and `Persona.binderSegments(for:) -> [BinderSegment]`
are pure, table-driven registries — the design's pane × persona matrix made executable.
A later milestone that adds a right-pane surface adds its `DetailSegment` case and one
entry in `panes`; it touches neither `DetailPaneToggle`/the View menu dispatch, nor
`ProjectWindow`. `PersonaPaneRegistryTests.test_everyPersona_matchesTheDesignMatrix`
checks the whole table at once (a row-at-a-time sweep lost a cell twice during this
milestone's own development — Review's translation/palette cells, then Plan's tasks —
which is why the test is a table diff, not a per-row assertion).

### 3. The keyspace migrated: personas take numbers, panes take mnemonic letters.

`⌘1`–`⌘4` now select personas. The nine pane shortcuts moved off the exhausted numeric
space onto `⌘⌥`-letter, one per pane and stable across every persona that offers it:
`⌘⌥I` Inspector, `⌘⌥R` Research, `⌘⌥O` Outline, `⌘⌥A` Annotations (unchanged), `⌘⌥H`
History, `⌘⌥T` Tasks, `⌘⌥B` Inbox, `⌘⌥P` Palette, `⌘⌥L` Translation. Two existing
shortcuts had to move to make room: **Toggle Review Mode** `⌘⌥R` → `⌘⌥⇧R`, and **Toggle
Inspector** (the whole-column visibility toggle, distinct from the Inspector *pane*)
`⌘⌥I` → `⌘⌥0` — Xcode's own binding for the analogous "toggle inspector" action, chosen
so the retraining lands on a spelling a Mac-fluent writer may already have in muscle
memory from elsewhere.

This was forced, not stylistic: a flat `⌘⌥` numeric space tops out at 9 (⌘⌥1–8 plus the
pre-existing mnemonic ⌘⌥A), the redesign's five reserved future panes have nowhere to go
inside it, and the two rejected alternatives are worse — keeping today's numbers leaves
every persona showing an arbitrary sparse subset with no room to grow, and renumbering
*per persona* makes one keystroke mean a different pane depending on where you are,
which is worse for muscle memory than a one-time retraining.

Migrating the dispatch surface also fixed a real, unrelated bug: all nine pane shortcuts
now register as `Button`s in the View menu (`MaughamApp.swift`) rather than split across
menu commands (four) and `.keyboardShortcut` modifiers on `DetailPaneToggle`'s `Picker`
tags (five). The picker-tag shortcuts only fired when the picker was already on screen,
so `⌘⌥4`–`⌘⌥8` (History/Tasks/Inbox/Palette/Translation, pre-migration numbering) silently
no-opped whenever the inspector column was closed. Every pane shortcut now reveals a
hidden column before selecting its pane — *including* an out-of-persona one. Revealing a
hidden column mounts `DetailPaneToggle` fresh (the column is conditional on
`showInspector`), so the mount-time snap in `.onAppear` deliberately consults the
selection-carrying list, not the persona's bare registry: the writer's requested pane is
appended and kept. The one exception is `.outline` on a collection project, whose content
falls through to the inspector, so a tab would lie. Coercion to the registry belongs to
persona changes only, and the two call sites are documented apart in `DetailPaneToggle`
because conflating them cost three defects during this milestone.

### 4. Persona is per-window state, persisted per-project — with an honest limitation.

`persona: Persona` is `@State` on `ProjectWindow`, so two windows open on two different
projects (or the same project, opened twice) can sit in different personas
simultaneously — nothing about persona selection is process-global. It is written back
to `UIState.persona`, persisted at `.maugham/ui-state.json`, so a project reopens in
whatever persona it was last left in.

The honest limitation: `UIState` is a single JSON file per *project*, not per window, so
if two windows are open on the *same* project at once, they share one persisted value —
a freshly *opened* third window on that project starts in whichever persona the file
last recorded, not necessarily either currently-open window's live persona. Runtime
independence between windows already open holds regardless (each has its own `@State`
and only writes its own live value on change); what isn't independent is which persona a
*new* window opening on an already-open project starts in. This mirrors the existing
`detailSegment`/`outlineLayout` persistence shape in `UIState` — persona adds no new
sharing behavior, it inherits the one that shape already has.

### 5. ADR 0005 (right-pane mode-swap) is amended, not superseded.

The mode-swap pattern this ADR sits on top of — a picker at the top of the right pane
swaps its content, selection persists per project, shortcuts jump between modes and
reveal the pane if hidden — is unchanged in shape. What changes is scope: the picker no
longer offers all nine modes to every writer: `Persona.panes` filters which subset it
shows and in what order, and `Persona.coerce(_:)` handles landing on a valid mode when
the writer switches personas mid-pane. ADR 0005's `DetailPaneToggle`/`DetailSegment`
machinery is the substrate this milestone builds on, not something it replaces — its
Status stays Accepted, and this ADR is additive to it, not a supersession.

## Consequences

- Four `⌘1`–`⌘4` personas reconfigure all three columns without ever gating anything —
  falsifiable claim: if a future build makes any persona unreachable in any state, or
  requires completing one before entering another, this decision was violated.
- The pane registry (`Persona.panes` / `Persona.binderSegments(for:)`) absorbs the cost
  of future right-pane growth: one enum case, one table entry, no picker/window changes.
- Seven existing shortcuts were retrained (nine panes onto new letters, two collisions
  resolved by moving Toggle Review Mode and Toggle Inspector) — a real one-time cost, in
  a product that treats muscle memory as sacred, accepted because the alternative left no
  room for the five panes already on the design's board.
- The View-menu-only dispatch closed a real, independently-discovered bug (picker-tag
  shortcuts no-opping with the column closed) as a side effect of the migration, not a
  separately motivated fix.
- Per-project persona persistence has one narrow multi-window sharing edge (§4) that is
  pre-existing behavior for the rest of `UIState`, not a new one this milestone
  introduced — noted so nobody rediscovers it as a surprise.

## References

- Spec: `docs/superpowers/specs/2026-07-25-mode-based-ux-redesign-design.md` §6
  ("The shell" — persona switching, the keyspace, pane redistribution)
- Plan: `docs/superpowers/plans/2026-07-25-persona-shell.md`
- ADR 0005 (right-pane mode-swap — amended by this ADR, not superseded)
- ADR 0010 (typed cross-area seams — `Persona`/`DetailSegment` follow the same
  compiler-exhaustive registry pattern)
- ADR 0021 (scoped window events — `.maughamSetPersona` follows the `MaughamEvent`
  scoped-post discipline; the persona bar posts `.keyWindow`)
- `docs/constitution.md` must #2 ("Maugham imposes no method") — the principle §1 of
  this decision is written against
