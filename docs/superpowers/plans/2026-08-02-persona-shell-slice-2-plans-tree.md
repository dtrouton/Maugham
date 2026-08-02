# Persona shell, slice 2 — Plan's tree

*Plan, 2026-08-02. Executes slice 2 of
`docs/superpowers/specs/2026-08-01-persona-shell-workflow-design.md` §6.*

**Re-derived against the tree at `bca349f`, after slice 1 shipped.** Every
`file:line` below was read that day by the slice-2 reconnaissance pass; anything
not read then is marked unverified. Contracts and symptoms only — a plan's code
becomes the shipped defect (`memory/feedback_plan_code_is_a_liability.md`).

---

## What this slice is

Plan gets the manuscript tree on the left **with the canvas still in the centre**,
so Plan can produce what §2 says it produces — structure — and so Intent finally
has something to aim at. It closes §1's hole, which Denver hit within minutes of
opening Plan on 2026-08-02: *"the binder hasn't appeared in plan view."*

## Rulings taken before this plan was written

**1. A new `BinderSegment.tree` case, not a reuse of the manuscript home.**
The reuse option would make the *same enum case* mean "the editor" in Author and
"the canvas" in Plan — context-dependent meaning of the kind `SynthesisSource`
(tripwire 12), `MaughamSidecarPath` and `DeviceSlug` (tripwire 24) were each
introduced to remove. It also leaves five routing sites needing persona-awareness
with no compiler help, where a new case is forced by seven exhaustive switches and
its two risky spots are already covered by a census that loops `allCases`.

**2. Navigating to a manuscript document moves you to Author — but only from a
persona that would not show it.** Denver: *"if I'm moving to the manuscript I'm
moving to Author — I shouldn't be writing the manuscript in plan."* **Plan is the
only such persona**; Review and Publish both centre the editor, and forcing Author
out of Review would break adjudication, where clicking an annotation must show the
prose *in Review*. See task 5 — the guard is on the *current persona's centre*,
never a hardcoded `== .plan`.

**3. Plan ships four segments; the canvas/research redundancy is slice 7's.**
Recorded in §3.1.1's 2026-08-02 amendment. Slice 2 adds one segment and moves
nothing.

## What the reconnaissance refused or corrected — read this before task 1

- **`.tree`'s left pane is not `BinderView`.** That is right for one of three
  shells. A screenplay's tree is `SceneNavigatorPane`, a Collection's is
  `CollectionPiecesPane`. Task 1 owns the correction.
- **§3.1.1's *"the picker labels must carry that distinction"* is not
  implementable.** `BinderSegmentPicker.body` emits `Image(systemName:)` and no
  text at all — deliberately, because a mixed `Image`/`Text` `ForEach` shipped the
  2026-07-25 palette-unreachable defect, and because text was *measured* and
  rejected at 264pt against a 240pt column. The distinction can only live in the
  symbol, the tooltip and the VoiceOver label.
- **The recorded reason `.manuscript` was withheld from Plan is stale.** The
  comment cites a coercion rule that *"keeps any segment the destination offers"*;
  `PersonaMemory.restoredBinderSegment` replaced it and restores the
  **destination's** remembered position. Fix the comment (task 4).
- **`Persona.swift`'s *"every case above returns ≥2"* becomes false** when
  research leaves Review and Publish (task 6). Nothing enforces a binder floor —
  the ≥2 assertion in `PersonaPaneRegistryTests` is about the right-hand registry.

---

## Tasks

Ten, at the cap (CLAUDE.md rule 12). Tasks 1–3 are one chain; 5 and 6 are
independent and can start immediately.

### Task 1 — the `.tree` case and the pane it routes to

**Deliverable.** `BinderSegment.tree`, plus a static beside `documentHome(for:)`
that answers *"which pane does `.tree` show for this project type"* — `BinderView`
for novel/short story, `SceneNavigatorPane` for screenplay, `CollectionPiecesPane`
for a Collection.

**Contracts.**

- **One derivation, next to the one it mirrors.** `Persona.swift` already carries
  the rule: manuscript-shaped entries *"NEVER name `.manuscript` directly"* and
  route through `documentHome(for:)`. An inline `type == .screenplay` inside a
  toggle is the re-derivation that shipped the 2026-07-02 bug. Test it over
  `ProjectType.allCases`.
- **Seven exhaustive switches will not compile until answered** — `isTransient`,
  `displayName(for:)`, `pickerSymbolName`, both binder toggles, and both of
  `ProjectWindow`'s editor/inspector switches. None carries a `default:`, and that
  is the point. Do not add one.
- The picker symbol must be **distinct from every existing one** — pinned by
  `PersonaBinderSegmentTests.test_everySegmentHasADistinctPickerSymbol`.
- `.tree` is **not transient**. `.trash` and `.find` are; the picker appends those
  on their runtime predicates.

**Persistence needs nothing.** `UIState.binderSegment` decodes with a fallback and
`PersonaMemory` decodes via `compactMapValues(BinderSegment.init(rawValue:))`, so
an older build drops an unknown `"tree"` and falls back to `binderHome`. **No
migration** (tripwire 11).

### Task 2 — the canvas stops being remounted by a segment change

**This is the task most likely to be got wrong quietly, and it is not optional.**

`CanvasView` is mounted at exactly one site, inside `existingEditorSwitch`'s
`case .canvas` arm. Its **camera, layouts, thumbnail cache, in-progress scrap edit
and axElements are `@State` on the view** — `CanvasModel`'s own doc comment says
so from the other side (*"What deliberately does not live here: camera,
layouts…"*).

Two separate `case` clauses in a ViewBuilder `switch` are two distinct branches,
so `.canvas` and `.tree` as separate arms **destroy and rebuild the canvas** on
every flip: camera to origin at zoom 1, every layout re-measured, thumbnails
emptied, `.onAppear` re-running `load()` and re-reading `canvas.md` and the
sidecar.

**Deliverable.** One branch serves both. The cleaner shape — and the one the
window already uses next door — is to lift the decision out of the switch
entirely, mirroring `inspectorRoute`'s own doc comment: *"The canvas check sits
ABOVE the project-type split, in both columns."* A named pure route asked over its
whole input product beats a `case .canvas, .tree:` that a later editor can split.

**The test, and it is cheap:** put the camera somewhere non-default, flip
tree↔canvas, assert the camera did not move. **Recon marked the underlying
SwiftUI behaviour unverified-by-test in this app** — so measure it rather than
citing it, and if two arms turn out *not* to remount, say so and simplify.

### Task 3 — one predicate for "the centre is the canvas"

Three sites spell it as `binderSegment == .canvas` today and the compiler will not
catch a missed one:

- `inspectorRoute` — miss it and **the region inspector is unreachable from Plan's
  tree**, which is the exact 2026-07-28 smoke defect.
- `editorRoute` — miss it and, in a Collection with a reference piece selected,
  `.tree` shows the reference placeholder and **the canvas never appears**.
- `PersonaModifier.releasesCanvasCollapse`, spelled `leaves(.canvas, from:to:)` —
  miss it and a persona switch off `.tree` under a ⌘\ collapse never hands the
  sidebar back.

Also check `CanvasCollapseModifier`, which fires `.onChange(of: binderSegment)` and
re-derives through `inspectorRoute`: if `.tree` is not in the canvas check, a
writer in focus mode flipping tree↔canvas gets ⌘\ silently released and re-applied,
moving the sidebar under them while the canvas never left.

**Deliverable.** One segment-level predicate, used by all of them.

**`CanvasPersonaTests` is already the census for this** — two tests loop
`BinderSegment.allCases where segment != .canvas` and will go red until `.tree` is
handled. **Add `.tree` to the positive assertions as well as the exclusion**, or
the census quietly becomes an exclusion list.

**Decide and record:** `CanvasClaudeArrivalModifier.Destination` names
`(persona: .plan, binderSegment: .canvas)`. Should a Claude arrival pull the writer
off `.tree` onto `.canvas`, or leave them where they are? Either is defensible;
silence is not.

### Task 4 — Plan offers the tree

`Persona.plan.binderSegments` → `[.canvas, .tree, .research, .palette]`.

**Fix the stale comment in the same commit.** The `.plan` case argues that
`.manuscript` stays *"deliberately ABSENT"* because *"the coercion rule keeps any
segment the destination offers"*. That rule is gone. Say what is true now, and why
the tree is a different answer from the manuscript segment rather than a reversal.

`binderHome` is `binderSegments(for:).first`, so Plan still lands on the canvas.
Do not reorder without saying why.

### Task 5 — navigating to a manuscript document moves you to Author, from Plan only

**Deliverable.** The three sites that force the binder to the manuscript home also
move the writer to Author **when the current persona would not show the document**.

The sites, all in `ProjectWindow`: `.maughamNavigateToDocument` (a `[[wiki-link]]`
click, and the Project Statistics window — deliberately `.project`-scoped, *"must
navigate this project's window even when it isn't key"*), `.maughamCloseFind`, and
`ParagraphNavModifier`'s `.maughamNavigateToParagraph`.

**Contracts.**

- **The guard is on the current persona's centre, never `== .plan`.** Review and
  Publish both centre the editor; clicking an annotation or a history row in
  Review must show the prose **in Review**. Ejecting a reviewer into Author would
  break adjudication, and a hardcoded persona test is how that ships.
- **Plan is the only persona this moves today**, and that should fall out of the
  rule rather than be asserted by it. Test it across all four personas.
- `.maughamNavigateToDocument` is **cross-window**. A persona write on that path
  changes a background window's persona. Say whether that is intended.
- `applyPersonaChange` records the departing position, so ⌘1 returns the writer to
  where they were in Plan. That is a feature — check it holds.

**Reachable-from-Plan paths, verified, so the test drives a real one:** a
`[[wiki-link]]` in the **Intent pane** (`StatementEditorHost` wires
`wikiLinkClickResolver`; `.intent` is a Plan pane), the Inspector's Links row, a
Tasks row, closing a cross-document find, and the statistics window. **Not** a
research note — `ResearchNoteEditor` never wires the resolver, so those links are
inert. That is a known gap, recorded, and not this slice's.

### Task 6 — research leaves the left column of Author, Review and Publish

*Independent of tasks 1–5; start immediately.*

Spec §6.1. `.author` → `[home, .palette]`, `.review` → `[home]`, `.publish` →
`[home]`.

**Contracts.**

- **Fix `Persona.swift`'s *"every case above returns ≥2"*** in the same commit.
  Nothing enforces a binder floor; `binderHome` handles a one-element list.
- **Check the one-segment picker renders sanely.** Recon read the code and marked
  this **unverified by measurement**. The single-button state is the
  empty-trash, not-searching, on-home case — common, not universal.
- **Say the asymmetry out loud in the commit**, because smoke will meet it: two
  event routes still set `.research` in Author — the **Open** button on a promoted
  canvas card, and the **Show** button on the MCP note banner. Both land via the
  picker's append-the-current-selection rule. So after this, Author has no picker
  route *in* and two event routes in, and no way back but ⌘1.
- Collateral, cosmetic, flag don't fix: ⌘⇧P "Toggle Research Preview" has no
  visible effect in Author once the segment is unreachable by picker.

### Task 7 — structure creation from Plan's tree

**Mostly a verification task, and that is the finding.** `BinderView` carries its
root context menu, its per-row menu and its empty-state buttons, all attached to
the view rather than gated on persona — so mounting it in Plan brings structure
creation with it. `CollectionPiecesPane` brings its `+` menu the same way.
`addStructureItem` has exactly one production call site and must keep having one.

**Deliverable.** Confirm by driving it in Plan, not by reading. Then state
plainly, in the plan's own record and in the guide, that **a screenplay has no
structure creation here and should not gain one** — a screenplay is one
`.fountain` and its "structure" is sluglines, typed in the editor, which is not on
screen in Plan. `SceneNavigatorPane`'s empty state already points at the script
row for exactly this reason.

### Task 8 — the docs the slice makes false

- **§3.1.1's *"the picker labels must carry that distinction"*** — correct it to
  what is buildable: symbol, tooltip, VoiceOver label. Note the pair it worries
  about most (`canvas` vs `research`) is already distinguished today.
- `docs/guide/right-pane.md` and `getting-started.md` describe each persona's
  columns — both change.
- `docs/guide/structure-and-binder.md` — Plan now has a tree.
- The two stale `Persona.swift` comments (tasks 4 and 6) if not already done.

### Task 9 — censuses and count literals

- **`CanvasSegmentTests` asserts `BinderSegment.allCases.count == 7`** — a literal
  count over a list, the shape `memory/feedback_prose_counts_are_unmaintainable.md`
  is about. **Replace it, do not bump it.**
- Whatever else the built code shows is warranted; an argued "none" is acceptable.
  If you build a census, give it a **planted-offender companion and a control**.

### Task 10 — whole-branch review

It has found a Critical in **nine** consecutive slices, including slice 1's. Give
it the ledger, and ask **"what does this change make newly possible?"** as its own
step, separate from "does each task do what it said".

---

## Not in this slice

- **What the centre shows when the subject is the project.** Logged in the spec
  against slice 2, but it does not block: in Plan the canvas ignores the subject
  entirely, and **slice 3** is where Plan's centre starts responding to the tree
  selection. The Author-side question (an outline instead of a placeholder?)
  stays open, with the recorded caution that `OutlinePane` is read-only and slice
  1 removed it from every persona's picker.
- The canvas/research redundancy — slice 7.
- The screenplay's two header rows — provisional, and judged by the centre
  question above.
- **Issue #21** — still to be decided before slice 4.

## Method

- **opus** on tasks 1, 2, 3 and 5; task 8 is haiku work; tasks 6, 7, 9 are
  sonnet-or-opus.
- **Refusing a ruling in this plan that you can falsify is the standard.** Every
  agent on slice 1 refused something and every one was right — including one that
  showed a guard I specified would have missed half its defect, and one that
  measured my stated risk to be the wrong risk entirely.
- Quote a signature only if you read it out of the tree that day, with `file:line`.
- `./gen.sh` before any count you quote.
- **`-only-testing` suite paths are flat** — a folder-shaped path runs zero tests
  and exits 0, which reads exactly like green. It bit an implementer on slice 1
  and it bit me.
- **A driver that only half-works looks like a pass.** Slice 1 measured that a
  synthesised click drives a SwiftUI `Button` but never moves `List(selection:)`,
  while `selectRowIndexes` never touches a Button's hit-testing. Any test driving
  binder rows must actuate both ways or say why not.
- Baseline at `bca349f`: **4093 Mac tests, 0 failures.** The two documented
  wall-clock MCP tests passed on the last two runs; if they fail, apply the
  in-suite-fails / in-isolation-passes discriminator before believing it is yours.
- **A Release build before reporting** — `ProjectWindow.body` is in the blast
  radius of tasks 2 and 3.
- **No prose counts over lists.** Name the members.
