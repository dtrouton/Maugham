# Persona shell, slice 1 — the subject-picker

*Plan, 2026-08-01. Executes slice 1 of
`docs/superpowers/specs/2026-08-01-persona-shell-workflow-design.md` §6.*

**Everything quoted below was read out of the tree on 2026-08-01 at `3a57108`**,
by three reconnaissance passes whose reports are the evidence for the claims here.
A signature or line number not read that day is marked **unverified**. This plan
carries contracts and symptoms, never function bodies — a plan's code becomes the
shipped defect (`memory/feedback_plan_code_is_a_liability.md`).

---

## What this slice is

The tree becomes the window's single subject-picker. Spec §3.3: *"There is no way
to select the project."* Adding a project row closes §1's hole at the cause, and
**deletes a workaround rather than adding a feature** — `StatementPane`'s
`[Chapter | Project]` switch exists only because the tree cannot say "the project",
and that pane-local scope concept is what the reverted `Open`-sets-scope work
collided with for three fix rounds.

Plus the registry moves that clear out dead panes.

## Two rulings taken before the plan was written, and why

**1. The subject is a typed value, not a second magic string.** Denver's call.
The reconnaissance recommended it and sized it honestly; the alternative (a second
named constant) was on the table and was declined.

The problem it solves: `selectedItemId: String?` currently carries three meanings —
`nil`, a `StructureItem.id` that may be a document *or* a group, and (after
`?? "__no-selection__"` at three call sites but **not** at `ProjectWindow.swift:337`)
a fourth. A project row would make it five. Every site that must answer *"is this a
manuscript document?"* is today free to answer with any of: a sentinel string
compare, a `TreeWalk.find` + `type` test, a `documentStore.document(forDocId:)`
lookup, or **nothing at all**.

The precedent is `DeviceSlug` (tripwire 24), where *"enforcement = the compiler"*.

**2. ⌘S skips the breadcrumb when the subject is not a document, and still writes
the project entry.** Denver's call. See task 4 — this is a defect that ships today.

## What the reconnaissance refused, and what it cost the plan

Recorded because a refused premise is worth more than a confirmed one, and all
three of these changed the shape of the work:

- **`"__no-selection__"` is well-contained.** My brief called it a danger; it is
  not. The load-bearing shape is `TreeWalk.find(id:in:) + item.type == .document`,
  and it *already* rejects a group, an unknown id and a new sentinel alike —
  deliberately, in `StatementPane.effectiveScope`, `InspectorView.currentItem`,
  `EditorHost.currentItem`, `ProjectWindow.selectionIsDocument`, `activeDocument`,
  `ResearchScope.researchRouting` and `InboxPane.activePromoteTarget`. The typed
  change is worth doing for the reasons above, **not** because the string is
  leaking.
- **An unregistered pane is still fully reachable**, so "outline leaves every
  persona" is a *demotion*, not a removal — see task 5. `PersonaPaneRegistryTests`
  contains a test whose failure message asserts the opposite, and that message is
  simply wrong.
- **Issue #21 has two mechanisms, not one** — see the note at the end. Slice 1
  does not fix it, and this plan must not let a task quietly half-fix it.

---

## Tasks

Ten tasks, at the cap (CLAUDE.md rule 12). Tasks 1–4 are one dependency chain;
task 5 is independent and can run in parallel from the start.

### Task 1 — `BinderSubject`, and the boundary that converts it

**Deliverable.** A `Hashable` enum with a `project` case and an `item(String)`
case, replacing `String?` as the type of `ProjectWindow.selectedItemId` and the
bindings beneath it. The conversion to a bare doc-id `String` happens **once**, at
the `ProjectWindow` boundary, for the consumers that legitimately want a doc id.

**Contracts.**

- Every existing meaning survives: `nil` (no selection) and `item(id)` for both
  documents and groups. `project` is new.
- The `"__no-selection__"` substitution stays at the boundary for the four
  consumers that take `activeDocId` (History, Tasks, the annotations arm, the
  translation arm). **Do not** push the typed value into those panes in this task —
  that is scope creep into slice 4's territory.
- `ProjectWindow.swift:337` passes raw `selectedItemId` to
  `TranslationReviewModifier` as `activeDocId` **with no sentinel substitution** —
  a third spelling of the same defaulting rule. Make the boundary produce one
  answer; do not preserve the inconsistency.

**Verified call sites** (read 2026-08-01; `./gen.sh` before quoting any count):
`ProjectWindow.swift`, `BinderView.swift`, `BinderPaneToggle.swift`,
`CollectionBinderPaneToggle.swift`, `CollectionPiecesPane.swift`,
`CorkboardGrid.swift`, `OutlinePane.swift`, `OutlineTable.swift`,
`DetailPaneToggle.swift`, `EditorHost.swift`, `InspectorView.swift`,
`IntentAffordanceRow.swift`, `PieceInspector.swift`, `StatementPane.swift`,
`TasksPane.swift`, `HistoryPane.swift`, `LinkedResearchPane.swift`,
`InboxPane.swift`, `UIState.swift`.

**The part most likely to bite, flagged by the agent that sized it and
deliberately not resolved on paper:** SwiftUI's `List(selection:)` /
`Table(selection:)` bindings at `BinderView.swift:17`, `CollectionPiecesPane.swift:30`
and `OutlineTable.swift:10` need `Binding<BinderSubject?>` and a `.tag` of the
matching type on **every** row. `.tag` type inference under `List(selection:)` is
the risk. **Measure it before designing around it** — if a `.tag` refuses to infer,
report what the compiler actually said rather than working around it silently.

**Do not** add a `rawValue`-style string round-trip for convenience. The point of
the type is that a site cannot get a `String` without deciding what a project
subject means.

### Task 2 — the project row

**Deliverable.** A row at the head of `BinderView`'s tree naming the project,
selecting `BinderSubject.project`.

**Contracts.**

- `BinderView.swift:132` is the **only** call site of `addStructureItem`
  (spec §7) — the row must not become a second one.
- Tripwire 9: no `.onTapGesture` for clickable rows inside `List(.sidebar)`. The
  row participates in `List(selection:)` like any other row; it is not a button
  bolted on top.
- The row is not renamable, not draggable, not a drop target, and has no context
  menu of its own in this slice. If the binder's root context menu already covers
  right-click on empty space, the project row must not shadow it.
- Tripwire 16 if any focus work is needed: inline-rename focus needs the 30 ms
  deferral **and** both triggers. Not expected here — flagged so a "small
  improvement" does not reintroduce it.

**Symptom to check by hand:** selecting the project row and then a chapter and
back must not disturb the editor's cursor. Tripwire 3 — no heavy work in a
synchronous binding setter.

### Task 3 — the selection survives a relaunch

**Deliverable.** Selecting the project, quitting and reopening lands back on the
project.

**Why it is a task and not a footnote.** `ProjectWindow.swift:1603-1611` validates
the restored selection with `TreeWalk.contains(id:in:)`. A project subject is not
in `manifest.structure`, so **the restore fails on the new build too** and silently
lands on the first document. This is not an old-build concern — it is a
this-build bug the moment task 2 lands.

**Contracts.**

- `UIState.selectedItemId` (`UIState.swift:9`, encoded at `:61`, decoded with
  `decodeIfPresent` at `:69`) needs a representation for the new case and a decode
  that still accepts the **old plain string** — an existing `ui-state.json` holds a
  bare id.
- **No schema bump and no migration** unless the codec genuinely cannot be made
  tolerant; CLAUDE.md's answered question is "no migration unless asked".
- An **older build** reading the new value must land gracefully. Verified today:
  `TreeWalk.contains` returns false and it falls to the first document — the same
  path a deleted item already takes. Confirm this still holds after your codec
  change rather than inheriting the claim.

### Task 4 — ⌘S stops writing op-log streams named after non-documents

**This is a defect that ships today, independent of everything above.** Verified
by reading the source, not inferred:

`CheckpointCapture.run` (`Maugham/OpLog/CheckpointCapture.swift:9-53`) takes
`activeDocId: String`, appends an op with `docId: activeDocId`, and **tests it
against nothing** — not a sentinel, not the structure. `ProjectWindow.swift:137`
and `:1678` both feed it `selectedItemId ?? "__no-selection__"`.

**Symptom today:** select a *group* in the binder, press ⌘S →
`.maugham/ops/<groupId>.<slug>.jsonl` appears, holding one checkpoint op. Delete
the selected document (the one `nil` site, `BinderView.swift:193`), press ⌘S →
`.maugham/ops/__no-selection__.<slug>.jsonl`.

**Why it stops being cosmetic:** `OpLogStore.docId(fromOpLogFilename:)`
(`OpLogStore.swift:260-274`) excludes exactly one synthetic stream — `__project__`
— so these parse as **real doc ids**. `DocumentStore` seals them on every project
open, and on the phone `AnnotationsStore` and `ColdLaunchDownloader` enumerate and
download them. The project row makes a constant of what is currently an edge case,
because the project row is the natural landing place.

**Deliverable (Denver's ruling).** When the subject is not a manuscript document:
**no breadcrumb op**, and the project-wide `checkpoints.jsonl` entry is still
written, the pending-burst force-flush still runs, and the ⌘S flash still fires.

**Contracts.**

- ⌘S is a labeled checkpoint, not a save — a hard invariant. **The muscle-memory
  flash must not change**, including in the failure case (`feedback_ux_reflexes`).
- Do **not** route the breadcrumb to `__project__`: that stream carries
  project-scope *task* ops and is read by `TaskDeriver`, `TasksPane.ownerDoc` and
  `ProjectStore.projectTasksOpLog()`.
- The guard belongs where the decision is, not smeared across both call sites.

**Test.** Press ⌘S with a **group** selected and assert no new file appears under
`.maugham/ops/` — a test that fails against unmodified code today. Then the same
for the project row.

### Task 5 — the registry moves

*Independent of tasks 1–4; start it in parallel.*

**Deliverable.** `Persona.panes` (`Maugham/Models/Persona.swift:92-131`):
`.outline` leaves all four; `.translation` and `.intent` leave `.publish`;
`.history` joins `.author`.

**Consequences that are the design, not accidents** — state them in the case
comments rather than letting a reviewer rediscover them:

- **Publish's default pane moves from Translation to Visual Language**
  (`defaultPane` is `panes.first`), and Publish lands on exactly the two-pane floor
  `PersonaPaneRegistryTests` asserts. The `.inspector` deviation stops being a
  nicety and becomes the only thing holding that floor — which is precisely why
  spec §5 refuses to remove it before slice 4 gives Publishing its own pane.
- **`.history` in Author fixes a documented papercut.** The comment at
  `ProjectWindow.swift:1615-1624` cites *"⌘⌥H in Author, quit, reopen → History
  gone"* as the regression that made the launch restore verbatim. Registering it
  changes History from summonable-but-forgotten to a pane `PersonaMemory` keeps.
  **That comment's worked example dies with this change** — re-point it at another
  pane rather than leaving it naming a case that no longer applies.

**The matrix test has to be re-decided, not mechanically edited.**
`PersonaPaneRegistryTests` transcribes §6.3 of the **umbrella** spec as a literal
`designMatrix`. The 2026-08-01 spec is *"an amendment in force to §6.3"*, so the
transcription's authority moves to the new spec's §5 table. Re-cite it there. A
`designMatrix` edit without that re-citation leaves the test asserting a matrix no
document contains.

**And one test is guarding a property the design denies.**
`test_everyDetailSegment_appearsInAtLeastOnePersona` fails outright when `.outline`
leaves every registry, and its message reads *"is registered in no persona and is
unreachable"*. **That claim is false.** Verified: `MaughamApp.swift:222-223` binds
⌘⌥O unconditionally; the key-window handler sets the segment with no registry
check; `DetailPaneToggle.visibleSegments(including:)` *appends* an unregistered
selection (its own doc comment: *"Personas are lenses, not gates"*); and
`segmentContent` renders `OutlinePane` on `hideOutline` alone. Spec §8 says the
same thing normatively. `DetailPaneTogglePersonaTests.test_mountSelection_landsOnThe
RequestedPaneInEveryPersona` already proves it for every persona × segment pair.

Delete that test **with the argument recorded**, or rewrite it to pin the property
that actually holds. Do not "fix" it by keeping `.outline` in a registry to make it
pass.

**Also red, each needing a decision rather than a nudge:** `StatementPaneTests.
test_intentIsOfferedByEveryPersona` (added by M1A, and its doc comment asks that a
sweep dropping it *"names the milestone that added it"* — name this one),
`PersonaMemoryTests:42` and `:122-126` (the latter's comment *is* its assertion:
*"Author does not offer History"*), `PersonaModifierTests:99-110`,
`UIStateTests:121`, `DetailPaneTogglePersonaTests:55-59`.

### Task 6 — the delivery-path test that three fix rounds needed and never had

**Do this before task 7, not after.**

`ProjectWindow.openPromotedArtifact`'s comment (`ProjectWindow.swift:1424-1440`)
records why `Open`-sets-scope failed three times and was reverted by ruling:

> *…three rounds each closed their finding and each opened a new one in a cell the
> last had right, because the pane's scope switch, the request and
> `prefersProjectScope` interact and **no test drives a press through the binding
> and back through this view's state** — every `StatementPane` in
> `StatementMountFixture` is mounted without one. The next attempt should start
> from that test, not from the control.*

That blocker is still open. `StatementMountFixture` mounts `StatementPane`
**directly** (`StatementMountFixture.swift:94-115`), never through
`DetailPaneToggle` or `ProjectWindow`, so nothing in the suite exercises
`detailSegment`, the selection binding and the pane's own state together.

**Deliverable.** A test that drives a real selection change through the binding and
observes the pane's resolved scope on the other side. M1A's own lesson is the
standard: *for anything with a menu item, key equivalent or gesture, one test must
model the real delivery path* — 22 green undo tests once sat on a ⌘Z that could not
reach the stack.

**Plant an offender**: make the binding a no-op and confirm the test goes red. **A
plant that does not fire is the finding**, not a formality — that happened twice on
M1A and both times the test was wrong, not the code.

### Task 7 — the pane-local scope switch goes

**Depends on tasks 1, 2 and 6.**

**Deliverable.** `StatementPane`'s `[<chapter> | Project]` `Picker` and its
`prefersProjectScope` state are gone; `effectiveScope` loses the parameter and
takes the typed subject.

**What dies with it** (verified, so nothing is left orphaned):
`selectedDocumentTitle` (its only consumer is the picker arm),
`.onChange(of: activeDocumentId)` (exists solely to reset the switch), and the
doc-comment paragraph promising *"the other one click away"*.

**A design decision the slice must make rather than fall into.** The header's
`else` arm (the caption) renders **only when no document is selected**. With the
picker gone, a selected document leaves the pane with no header at all. Decide what
the header says now that the tree names the subject — do not let it become an empty
`VStack` by omission.

**Contracts.**

- The resolution rule must survive verbatim: **`.document(id)` only for an id
  naming a `type == .document` item in *this* manifest; everything else is
  `.project`.** `createStatement` throws `.structureMissing` otherwise, so a scope
  the pane offers but the store refuses is a keystroke that fails.
- With `BinderSubject`, `project` becomes an **explicit arm**. It would fall
  through to `.project` anyway — do it explicitly regardless, because an implicit
  and a deliberate `.project` look identical until someone gives the project row an
  id that *is* in the structure.
- **`test_theProjectsIntentIsOneClickAwayFromADocuments` must be deleted
  deliberately** — the promise it pins is exactly what the project row replaces.
  That deletion is the slice's, not a tidy-up's.
- `InspectorIntentAffordanceTests:210-216` asserts `IntentAffordanceRow.scope` and
  `StatementPane.effectiveScope` agree. Once the parameter is gone both are the same
  call with the same arguments and **the assertion cannot fail**. Flag it; do not
  keep a test that cannot go red.
- Tripwire 6 stands: no parallel observable state on the host. Removing state is
  the direction of travel — do not replace the switch with anything.
- There is a grep census over `resolvedScope`'s readers in `TripwireGrepTests`,
  with a planted-offender companion and a control. **A new reader must be declared
  there with a reason.** It does not cover values other than that marker — the
  honest limit of a token census.

**`IntentAffordanceRow` is NOT removed here** — that is slice 4. It passes a literal
`false` today and only loses an argument.

### Task 8 — the docs the change makes false

Same commit as the change, per CLAUDE.md rule 10. Every item verified false-after,
not guessed:

- `docs/guide/right-pane.md:9-12` — all four persona pane lists, which are
  transcriptions of `panes` **in registry order** and so encode the defaults too.
- `docs/guide/getting-started.md:24` — *"Publish leads with Translation"* becomes
  false. The same sentence's *"switching away and back puts both columns exactly
  where they were"* becomes imprecise for Outline specifically (summonable, not
  remembered) — say so or stop claiming it.
- `ProjectWindow.openPromotedArtifact`'s comment — *"the pane's own switch is the
  way across"* names a control that no longer exists. **It moves or goes in this
  commit**; it is a `git grep` away from being a lie.
- `StatementPane.swift:22` and `:63` claim `"__no-selection__"` *"is a real value
  that arrives here, not a hypothetical"*, and `StatementPaneTests:95` repeats it.
  **Verified false today**: this pane is fed `activeManuscriptItemId`, which is the
  raw `selectedItemId` (`ProjectWindow.swift:1222`), not the `??`-substituted
  `activeDocId` (`:1226`). Keep the defensive arm; drop the claim it is exercised.
- `CLAUDE.md`'s `Maugham/Views/` row spells the pane keyspace as ⌘⌥I/R/O/A/H/T/B/P/L
  — **already stale** (it predates ⌘⌥N and ⌘⌥V) and inside the blast radius.
- `docs/guide/reference.md` and `docs/guide/right-pane.md` are the two
  mechanically-gated docs (`DocSyncTests`). Note the shortcut gate is
  **one-directional**: a token in the source missing from the doc fails, a stale row
  in the doc naming a shortcut the source no longer binds **passes**. Do not lean on
  it.

### Task 9 — tripwire and census work

**Deliverable.** Whatever of the following the built code shows is warranted — and
an argued "none" is an acceptable answer for any of them:

- A census over the sentinel literals if any survive task 1.
- A tripwire for the ⌘S guard if task 4's test does not already pin it at the
  delivery path.
- Whether `BinderSubject` deserves the `DeviceSlug` treatment (a private init, so
  the compiler is the enforcement).

**A defect *shape* that recurs is not retired by warning the next implementer**
(`memory/feedback_census_over_warning.md`): eight instances landed in one slice,
every one forewarned. If you build a census, give it a **planted-offender
companion** and assert a **control**, so it cannot be silently unfalsifiable.

### Task 10 — whole-branch review

Not optional and not a formality: **it has found a Critical in every one of the
last eight slices**, in files no task's diff contained. Give it the ledger of what
each task changed.

**The question that earns its keep** — ask it as its own step, separate from *"does
this address the finding"*:

> **What does this change make newly possible?**

That question caught the last three defects in `StatementEditorHost.swift`,
including two Criticals **introduced by fixes that were themselves correct**.

---

## Not in this slice

- **Issue #21** — decided before slice 4, per Denver. **The reconnaissance found it
  is two mechanisms, not one**, which is new information the issue does not yet
  carry: the `⌘⌥N`/`⌘⌥V` path gives `.intent` and `.visualLanguage` separate `case`
  arms in `segmentContent`, so that route **tears the host down** rather than
  reconciling it — `release()` never runs, and the draft dies with the discarded
  `StatementTextTarget`. A fix aimed only at `release()` closes one of the two.
  Also verified: `StatementEditorMountTests.test_aMintAndAReturningPaneDoNotBothBind
  TheSameStatement` **pins the loss as current behaviour** — its expected value
  omits the typed character, so a correct fix turns that assertion red. That is the
  signal, not a regression.
- **`IntentAffordanceRow`'s removal**, synopsis, the canvas highlight, Plan's tree,
  Review's posture — slices 2–6.
- **A Collection *reference* piece can be given a local intent.** `createStatement`
  → `documentSlug` checks only `item.type == .document`, and a reference piece is
  `type: .document` with `pieceKind: .reference`, so typing there mints a local
  intent about another project's document. **Analysis, not driven** — recorded here
  so it is not lost, and it is not this slice's.

## Method

- **opus** on tasks 1, 4, 6 and 7; **haiku** is enough for task 8. Task 5 is
  registry text but its test decisions are real judgment — sonnet or opus.
- **Refusing a ruling in this plan that you can falsify is the standard, not an
  escalation.** Eleven implementers did it on M1A and **every one was right** —
  including one that disproved a claim in the spec and one that overrode a
  controller deferral with a measurement. If a contract here is wrong, say so with
  the evidence and stop; do not implement around it.
- Quote a signature only if you read it out of the tree that day, with `file:line`.
- `./gen.sh` before any count you quote.
- **`-only-testing` suite paths are flat.** A folder-shaped path runs zero tests
  and exits 0, which reads exactly like green.
- **MaughamCore's own suites are run by NEITHER scheme** — reach them with
  `cd Packages/MaughamCore && swift test`. CLAUDE.md's build-flow section calls the
  Mac scheme *"Mac app + MaughamCore"*, which is true of the build and false of the
  tests.
- Three MCP tests are wall-clock dependent — apply the in-suite-fails /
  in-isolation-passes discriminator before believing a red run is yours.
- A **Release build** before reporting, if you touched a view. The Release
  type-check budget is stricter than Debug, and `ProjectWindow.body` is in the blast
  radius of tasks 1 and 2.
- **No prose counts over lists.** Name the members.
