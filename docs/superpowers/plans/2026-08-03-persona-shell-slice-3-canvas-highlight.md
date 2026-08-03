# Persona shell, slice 3 — the canvas highlight

*Plan, 2026-08-03. Executes slice 3 of
`docs/superpowers/specs/2026-08-01-persona-shell-workflow-design.md` §4 **and its
§4.1 amendment**, which answers the four things §4's table could not.*

**Re-derived against the tree at `c3fc110`, after slices 1 and 2 shipped.** Every
`file:line` below was read that day by the slice-3 reconnaissance pass; anything
not read then is marked unverified. Contracts and symptoms only — a plan's code
becomes the shipped defect (`memory/feedback_plan_code_is_a_liability.md`).

---

## What this slice is

Selecting in Plan's tree changes what the canvas shows: the project undims
everything, a document lights what is bound to it, a document with nothing bound
says so and offers the next move. It makes `RegionBinding.references(forPiece:in:)`
visible in the app for the first time — until M1A it had **zero** production
callers, and it has exactly one today (`list_canvas`).

## The invariant everything hangs off

> **While anything is dimmed, a sweep binds to whatever the tree names. On an
> undimmed board, a sweep is just a sweep.**

The dim **is** the mode indicator. If a task finds itself adding a second signal
to say "binding is armed", the design has drifted.

## Rulings taken before this plan was written

All from §4.1: Escape is the keyboard spelling of the project row and **must lose
to the mounted scrap editor**; a group lights the union of its children's
bindings but a sweep while a group is selected makes a **plain region** and the
standing text never appears; a lit collapsed region stays as it is; the offer is
**standing text**, never a banner.

## What the reconnaissance settled, so no task re-litigates it

- **Sweep-binds is a CREATION and tripwire 31 licenses it.** `createRegion` reads
  `absorbedNodes` *before the region exists*; there is no prior relationship to
  break. The rule the tripwire protects — `setRegionFrame` deliberately not
  refreshing membership — is untouched by this slice.
- **It uses the INSIDE verbs.** A sweep is inside `CanvasView.handleDrag`'s own
  open bracket. `mutateFromInspector` here would **close a bracket the writer is
  still holding mid-drag**, and there is a converse census that fails if you do.
- **The lit set is scene-proportional and must not be derived per frame** —
  tripwire 30. `axElements` is the exact precedent: `@State`, rebuilt in an
  `.onChange`, read from `body`.
- **`sceneRevision` already covers both structural inputs** — the inspector's
  bind, a drop-join and a swept region all bump it; drag and coast frames
  deliberately do not.
- **The canvas cannot see the subject today** and gets it as a `let` passed at
  the one mount site, **not** as a stored property on `CanvasModel` — that object
  is written by every drag frame and the right-hand column deliberately reads
  nothing off it.

---

## Tasks

Eight. Tasks 1–3 are one chain.

### Task 1 — the canvas learns what the tree names

**Deliverable.** `CanvasView` takes the window's subject; `ProjectWindow` passes
it at the single mount site.

**Contracts.**

- A `let` on `CanvasView`, **not** a stored property on `CanvasModel`. The model
  is `@Observable` with the whole scene in one property that every drag frame
  writes; putting a right-column value there makes the inspector a writer into
  the drag loop's object.
- Two mount censuses exist and an added argument moves neither — confirm rather
  than assume.
- **`BinderSubject.item(id)` may name a GROUP.** The type deliberately does not
  encode document-vs-group, and `boundPieceID` can only ever hold a document id.
  Do not "fix" that here.

### Task 2 — the lit set, cached and never per-frame

**Deliverable.** Two derivations behind one cache: the lit **cards**
(`RegionBinding.references(forPiece:in:)`) and the lit **regions** (the regions
whose `boundPieceID` matches — a second derivation the projection does **not**
give you, since it dissolves regions away and returns a flat card set).

**Contracts.**

- Rebuilt on **`sceneRevision` *and* the subject**, in an `.onChange`, held as
  `@State`, read from `body`. **Deriving it inside the `Canvas { }` closure is
  tripwire 30's defect** — the AX tree once did exactly that and re-sorted the
  scene at 60–120 Hz.
- **A group unions its children's bindings** (§4.1). That is a third derivation:
  walk the group's descendant documents, union each one's lit set. Decide where
  it lives and test it over a nested group.
- Use `unorderedRegions`. `CanvasScene.nodes` and `.regions` **sort on every
  access**.
- **This makes the dim the second production caller of the projection**, and
  `RegionBindingTests`' caller census asserts the list by name and fails when it
  **grows**. That is by design: add the caller with a line saying what it consumes
  the projection for.
- The projection **includes hidden nodes** (residents of a collapsed region). The
  draw already culls them, so nothing needs special-casing — but if anything ever
  *counts* the lit set for the writer, the count and the canvas would disagree.
  Do not put a count on screen in this slice.

### Task 3 — the dim

**Deliverable.** Lit nodes and regions draw as they do today; everything else is
de-emphasised.

**Contracts.**

- **Alpha is replaced, never multiplied.** `CanvasMaterial` carries a warning
  from a shipped bug: `0.35 × 0.30 = 0.105` made a tether invisible. A dim
  applied as a multiplied opacity hits that at **four different starting alphas**
  — card paper, region wash, chip (0.75) and tether (0.30). Establish one dimmed
  material rather than a multiplier.
- The dim is a parameter on `draw`, beside `selection` — a non-scene, non-camera
  fact the view resolves and hands down, with the renderer deriving nothing.
  `drawCard`/`drawRegion`/`drawLine`/`drawTether`/`drawChip` each take their
  context **by value**, so a single top-level opacity will not reach them.
- **There is no existing emphasis concept** — everything that varies a node's
  appearance today (Claude's paper, the promoted stripe, the selection ring) is
  additive and per-object. Do not overload one of those.
- A dimmed card stays **clickable and selectable**. This is de-emphasis, not
  disabling.

### Task 4 — the sweep binds, inside the gesture

**Deliverable.** While the board is dimmed and the tree names a **document**, a
swept region is created already bound to it.

**Contracts.**

- **Inside `model.withScene(persist: false)` in `handleDrag`**, alongside the
  `model.selection = .region(id)` already there — one gesture, one ⌘Z that takes
  back the region *and* its binding together. The drop-join at the same site is
  the shape to copy.
- **Never `mutateFromInspector`.** See above.
- **A group selection creates a plain region** (§4.1) — the one deliberate
  exception to the invariant.
- A second sweep binds too. The projection already unions across regions and
  `list_canvas` already reports it, so nothing downstream needs teaching.

### Task 5 — Escape

**Deliverable.** Escape clears the dim, exactly as selecting the project row
does.

**Contracts.**

- **It must lose to the mounted scrap editor.** If a card's editor is up, Escape
  belongs to the text view. The canvas's `keyDown` today handles only ⌫ and
  forward-delete and falls through to `super` for everything else — keep that
  discipline and check the mounted-editor case **by driving it**, not by
  reasoning.
- Escape and the project row must produce the **same state**, not two states that
  look alike. Assert that.
- It changes the window's subject, so it is a write into `ProjectWindow`'s state
  from the canvas — decide the route deliberately and say why.

### Task 6 — the standing text

**Deliverable.** A document with nothing bound: the board dims and the canvas
says what to do next.

**Contracts.**

- **Standing chrome, not a banner** (§4.1), and not a fourth
  `.overlay(alignment: .top)` — three already share that window and two on screen
  at once draw over each other.
- It appears **only** for a document with an empty lit set. Never for a group,
  never for the project row.
- Refusable by ignoring it; no timer, no dismiss button, no recurrence
  (constitution: nothing is pushed).

### Task 7 — the dim is audible

**Deliverable.** A VoiceOver user can tell a lit node from a dimmed one.

**This is not optional and the precedent is exact.** ADR 0026 §10 gave Claude's
cards a spoken term *because a lean is inaudible*. A dim is inaudible by the same
argument, and this is the layer where a purely visual signal becomes a §7A.6
failure.

**Contracts.**

- Every label goes through **one** function whose ordering rule is explicit —
  kind, name, provenance, then durable facts. **Lit-ness is not a durable fact
  about the object**; it is window state that changes when the writer clicks a
  different row. Decide where it goes rather than appending it to that list.
- The AX rebuild currently triggers on `sceneRevision` alone. It now depends on
  the subject too, **or every label goes stale on a tree click** — the same
  dependency the lit set has, and it should be the same trigger.
- Repetition on every card is **acceptable and has a ruling**: the tree is flat,
  a card is not a child of its region, so a term spoken only on the region leaves
  cards reachable in silence.
- **Do not** implement the dim by removing nodes from the tree. It is available
  and it is cheaper, but it makes the dim a *removal* for a VoiceOver user where
  it is a de-emphasis for a sighted one, and a dimmed card is still clickable.

### Task 8 — whole-branch review

It has found a Critical in **ten** consecutive slices, twice by finding the seam
no task owned. Give it the ledger, and ask **"what does this change make newly
possible?"** as its own step.

---

## Not in this slice

- The reference **rail** (§4's *"what you cluster around a piece becomes what is
  pinned beside you"*) — that is M2's.
- One banner host for the window — its own slice, already recorded.
- **Issue #21** and the §5 palette/visual-language contradiction — both owed
  before slice 4 and slice 6 respectively.

## Method

- **opus** on tasks 2, 3, 4 and 7; tasks 1, 5, 6 are sonnet-or-opus.
- **Refusing a ruling in this plan that you can falsify is the standard.** Every
  implementer on this milestone has refused or corrected something and every one
  has been right — one found a fourth site I had missed, one showed my brief
  contained an impossible instruction, one refused a ruling outright with a
  better reading of it.
- **Plant an offender, and treat a plant that does not fire as the finding.** The
  sharpest use so far planted the *counterfactual* — what the lazy fix would look
  like — and showed it passed against broken code.
- `./gen.sh` before any count you quote.
- Build/test: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -skip-testing:MaughamTests/MCPServerLifecycleTests`. **Baseline at `c3fc110`: 4167 tests, 0 failures.** The two wall-clock MCP tests flake in-suite and pass in isolation; apply the discriminator before attributing.
- **`-only-testing` suite paths are flat**, and a path naming a folder **or a
  suite that does not exist** runs zero tests and exits 0 — which reads exactly
  like green.
- **A Release build before reporting.**
- **No prose counts over lists.** Name the members.
