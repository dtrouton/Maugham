# The persona shell — handoff after slice 3

*Written 2026-08-04, at the end of the session that flipped M1C, built slices 1
and 2, re-cut the right-pane registry, and took slice 3 to six of its eight
tasks. **Updated the same day**, after a second session finished task 7, ran
task 8's review and fixed its four findings. Paste the block below to start the
next session.*

---

We are continuing the **persona shell**. The design is
`docs/superpowers/specs/2026-08-01-persona-shell-workflow-design.md` — read §4.1,
§5.0 and §6.1/§6.2 first; all three are amendments written *after* the original
draft and all three overturn something in it.

## State

**Slice 3 is done, reviewed, SMOKED AND PASSED, and pushed.** `main` was pushed to
**`32cf7ef`** on 2026-08-04; the correctness work that followed the smoke is local
after it. **No tag** — the paired Mac + phone release is still deferred by choice
until the shell work lands, which is [[feedback-ship-whole-milestones]]: slicing
the implementation is fine, slicing the RELEASE is not.

| Slice | State |
|---|---|
| 1 — the subject-picker | **done, smoked** |
| 2 — Plan's tree | **done, smoked** |
| — the right-pane audit | **done, smoked** (not a numbered slice; it came out of slice 2's smoke) |
| 3 — the canvas highlight | **done, reviewed, smoked, pushed** |
| 4 + 5 — the Inspector dissolves, synopsis folds into intent | **merged, then PARKED** — see below |
| 6 — Review's posture | not started, **and it now comes first** |
| 7 — research becomes a view | not started, **deliberately unspecced** |

**Seven slices was over-cut, and 4/5 was the worst of it** (Denver, 2026-08-04:
*"this seems silly, is there any reason to have so many slices?"*). Synopsis IS an
Inspector section, so handing it to a later slice was a seam through the middle of
one change: slice 4 alone would have ended with an Inspector that had "dissolved"
and was still on screen holding a single field — a state nobody would ever smoke,
because it would never ship. They were merged.

**Then the merged slice was parked, on the reconnaissance rather than on
appetite** — Denver: *"these are good objections and change the ROI."* Full
findings are in spec §5.1's and §5.2's 2026-08-04 amendments; the short version:

- **§5.1's central claim is false.** Dissolving the drawer deletes the ONLY editor
  for Status, Tags, word target and page target — the same failure §5.1 already
  records for Publishing, four more times. Status would become a field Claude
  reads, the binder draws, and no writer can set.
- **"Tags → Plan" is structurally unavailable**, not merely unbuilt: Plan's
  `.inspector` IS the canvas inspector on both tabs, and the guide states that as
  intended.
- **Status's destination is slice 6's surface**, unbuilt and called M3's by
  `BinderSegment.swift`. So the dissolution follows Review's column rather than
  preceding it — which is also the order in which Status moves rather than dies.

**What is still worth doing on its own**, if this is picked up piecemeal: the
Publish config pane (the only destination that is a pure build with no open design
question, and what lets `.inspector` leave Publish's registry), and the synopsis
fold — whose own two findings are in §5.2's amendment, including that it blanks a
corkboard and an outline column, and that its migration must CLEAR the manifest
field or force a schema bump the phone refuses.

**The lesson, and it is the milestone's own, one layer up:** a spec table verified
three slices ago is a stale reading, and the reconnaissance that catches that is
worth more than the slice it cancels. Nothing here was wasted; the spec is now
right.

Slice 3's smoke found two things, both fixed and both in `main`: **Escape did not
reach the dim unless the canvas held the keyboard** (in full screen the first
press left full screen instead), and **a dimmed board gave no indication of what
was already bound**, so the never-re-bind ruling read as a silent refusal.

## Do this first

**Slice 6 — Review's posture.** It moved to the front when 4+5 parked, and the
order is now load-bearing rather than arbitrary: slice 6 builds Review's left
column, which is where the Inspector's **Status** field was always going. Build it
first and Status can move; build the dissolution first and Status dies.

**Before slice 6 starts, confirm §5's palette / visual-language contradiction**
rather than inheriting it — the three-column table and the "Leaving, by persona"
list disagree, and the delta list is recorded as normative. That is a stated
ruling a reader can falsify, which on this milestone has been right every time.

Everything that was owed before slice 4 is closed regardless: issue #21, the
dangling subject, and slice 3's own review findings.

Task 7 shipped `dimmedTerm` — *"outside the binder's selection"*, spoken FIRST,
ahead of the kind — and collapsed the two rebuilds into `rebuildHighlightAndTree()`
so the drawn card and the spoken card cannot describe different boards. The
stale-read shape was planted and **failed on this platform**: SwiftUI ran the AX
handler first, and the labels described the previous board permanently while the
canvas drew itself correctly.

Task 8's review found the eleventh consecutive Critical and it was again a seam
no task owned — see the commit `860a679`. Its shape is worth carrying forward:
**a pre-existing rule that was inert became load-bearing the moment a new
consumer read it.** Nothing about `restoredSubject` changed in slice 3; what
changed is who reads its answer.

## Still open, and neither is speculative

- **`selectedResearchId` and `selectedPaletteCardId` are not swept.** The subject
  fix validates against `manifest.structure` only; those two are separate `@State`
  in the same window over different id spaces, **and the research tree has a
  delete**. It is the same defect one tree over. Slice 7 turns research into a
  view, so it should be closed before then rather than by then.
- **§5's palette / visual-language contradiction** — the three-column table and
  the "Leaving, by persona" list disagree. Recorded with the delta list as
  normative; **slice 6 must confirm rather than inherit that reading.**

## Closed on 2026-08-04 — kept for the diagnoses, which were wrong in instructive ways

- ~~**Issue #21**~~ — **FIXED 2026-08-04**, before slice 4 reached that file.
  Words with no file yet now belong to the **scope** they were typed for, not to
  the pane that was showing it: `draft` became `typedBeforeItsFileExisted`, keyed
  by scope key, and `release()` no longer touches the words at all. `carryingDraft`
  is gone — it was a claim about *whose* words were in the box that the box could
  not check. **Not** a second copy of the text (tripwire 6): `deposit` removes the
  entry and writes it into the `Document` in one statement, so a run of characters
  is in the map or the file and never both. **It was four mechanisms, not two** —
  the two the reconnaissance found, plus `gateArrival`'s `.refuse` arm (clicking
  onto a chapter that HAS an intent, refused before the load with no `Document` to
  deposit into), plus `isMinting` being one host-level `Bool`, which meant a
  keystroke into a second undeclared scope while another mint was in flight started
  no mint at all. **Two** tests pinned the loss, not one. Still owed: the smoke —
  type one character into an Intent pane on a chapter with no intent, click another
  chapter, come back, and the character should be there.
- ~~**A deleted item leaves the window's subject dangling, at three sites and only
  one of them repairs it.**~~ — **FIXED 2026-08-04.** Denver's ruling: validate on
  structure change, in `ProjectWindow`. `SubjectValidationModifier` watches a
  fingerprint over the SET of structure ids and calls the same
  `ProjectWindow.validSubject` the restore calls, so the containment question is
  asked in one place and a dangling subject becomes `.project` at every moment
  rather than `.project` on open and `nil` at runtime.
  `BinderView.subject(_:afterDeleting:)` and its call site are gone. Two guards
  keep the sweep out of `load()`'s own window — the structure *appearing* is not
  the structure changing, and a sweep repairs a subject rather than choosing one
  — because a sweep in that gap would write `.project` through `updateUIState`
  into the very `ui-state.json` value `load()` has not read yet, and every reopen
  would land on the project row. **The finding inside the fix**: every mounted
  test attached the modifier itself and so stayed green with the window not
  attaching it at all (measured), which is the unreachable-half shape again — the
  attachment is now asserted where it is made. The record below is the diagnosis
  as filed.

  `BinderView.subject(_:afterDeleting:)`
  has one caller, `BinderView.deleteItem`. `deleteStructureItem` has three:
  `BinderView.deleteItem`, `CollectionPiecesPane.swift:95` (the piece context menu's
  Delete) and `ReferencePieceInspector.swift:71` (Remove). The latter two never run
  the fixup, so on a Collection deleting the selected piece dangles `selectedSubject`
  in the direct case. And even in `BinderView` only the deleted item's *own* subject
  is cleared — deleting a **group** takes its children out with it (`TreeWalk.remove`)
  and leaves a selected child dangling. All pre-existing and outside slice 3. M2's fix
  makes the CANVAS's consequence benign (undim rather than dead-dim); the residue is
  what `activeItemID`/`activeDocId` hand the editor, History, Tasks and the annotation
  arms. **It wants one shared answer across the three sites** — its own piece of work,
  and it should be decided before slice 4 rather than ridden.

## What this milestone has taught, and it is one lesson three ways

**A test that asserts the outcome can be green under the wrong implementation.**
It happened three times in slice 3 alone:

- the bind moved *outside* the gesture — "did the region get bound?" stayed green,
  and only the **undo** assertion caught it;
- the assign path failed to bump the structural counter — every state assertion
  stayed green, because a sweep that *mints* bumps it anyway and only a
  bind-without-mint exposes the gap;
- `XCTAssertNil(scene.region(id)?.boundPieceID)` passes when the **region** is
  absent — green on precisely the failure its own test existed to catch. Found by
  an existing tripwire, not by reading.

**And a plant that does not fire is the finding.** Twice in slice 3 that produced
something better than a fix: one disproved a claim its own author had written into
the source (a SwiftUI-level opacity *does* reach `withCGContext` drawing), and one
showed that a dim judged on cards alone cannot tell a replacement from a product,
because at alpha 1 they are the same number.

**The spec's sentences are the other recurring cause.** Three of them were built
literally and were wrong: *"sweep a region and it binds"* (only the empty-board
case), *"the picker labels must carry that distinction"* (the picker renders no
text at all), and *"the empty canvas's own standing instruction"* (that string is
drawn nowhere — it exists only in the accessibility layer). Each was found by an
implementer checking a claim against the tree rather than inheriting it. **Tell
implementers that refusing a stated ruling they can falsify is the standard** —
every one who did on this milestone was right.

## Mechanical

- `./gen.sh` before any count, **and after adding a test file** — doing it in the
  wrong order makes `-only-testing` run zero tests and exit green.
- **`-only-testing` paths are flat, and a path naming a folder OR a suite that does
  not exist runs nothing and exits 0.** That bit an implementer and it bit me.
- Baseline at `860a679`: **4249 Mac tests, 3 failures** — and the three are two
  test cases, `MCPColdStartTests.test_firstCallAfterLaunch_pollsUntilServerBinds_noPriorConnection`
  (two assertions) and `MCPBinaryIntegrationTests.test_binary_exitsCleanly_onStdinClose`.
  Both suites in isolation: 8 tests, 0 failures. Apply that discriminator before
  attributing a red run to your branch. (It was 4236 / 0 at `8795e3c`, before task
  7's ten and the fix round's three.)
- **Do not pipe `xcodebuild` through `tail` when you need the failure NAMES.** The
  summary line survives and the `Test Case … failed` lines do not, so a run reads
  as "3 failures" with nothing saying which — and re-running costs eight minutes.
- A **Release** build before reporting if you touched a view.
- If `CanvasView`'s memberwise init changes, expect stale-`.o` `Undefined symbol`
  errors; CLAUDE.md's clean-DerivedData case is real and was hit twice.
- **Do not `git add -A` while a subagent is working.** `0c1930c` describes a spec
  change and carries 663 lines of code because I did.

## Smoke — slice 3's list is discharged; this is what is owed NEXT

**Slice 3 was smoked and passed on 2026-08-04.** Two items on the list below came
back as real finds and both are fixed in `main`; they are struck through rather
than deleted, because the shape of each is worth carrying.

**Owed now, and none of it has been run by a human — it all landed after the
push.** The subject sweep is the behavioural one and its two cases are exactly the
ones no test could have been trusted to speak for:

- **Delete a GROUP that contains the chapter you have selected.** The window must
  move to the project row rather than sitting on a chapter that no longer exists.
  This is the case the old rule got wrong: it compared ids, and a group's children
  do not carry the group's id.
- **On a Collection, delete the piece you have selected**, from the piece context
  menu and from the reference inspector's Remove. Neither site repaired anything
  before, so both dangled in the direct case.
- **Rename and reorder the selected item, and drag it to a new parent.** Nothing
  should move. The sweep is keyed on the SET of ids so those cannot fire it — but
  a selection quietly jumping during a drag would be a worse bug than the one this
  fixed, so it is worth one pass by hand.
- **Publish something.** The `ProjectStoreASTSource` change is an isolation
  annotation with no behavioural intent, but it sits under PDF and EPUB compiles,
  and "no behavioural intent" is a claim rather than an observation.

~~**Issue #21**~~ — smoked and passed as part of slice 3's pass: one character
into an Intent pane on a chapter with no intent, click away immediately, come
back, and it is there. Both routes.

- ~~Sweeping across a region bound to a **different** chapter does nothing at all —
  no bind, no region, no explanation.~~ **Found, and fixed** (`32cf7ef`): a dimmed
  region bound elsewhere now names the piece it belongs to, so the refusal is
  predictable before the gesture rather than explained after it. The rule that
  falls out: **no name on a dimmed region means a sweep there will work.**
- ~~**Escape only reaches the canvas when the canvas has focus.**~~ **Found in full
  screen, and fixed** (`5da41a1`): the first press left full screen. It was never
  about full screen — an unhandled Escape simply travels up the responder chain,
  and `NSWindow` is the first thing that wants it. A window-scoped local monitor
  now sees it before any window does.
- A lit region that is **collapsed** lights one rectangle and no cards.
- **A dimmed card being edited shows ghost paper under full-strength live text.**
  The mounted `NSTextView` receives no dim while `drawCard` draws the paper at
  0.22, and there is a visible pop when `visibleEditorNodeID` flips — drawn text
  sits dimmed for the ~120 ms straighten, then jumps. The design is right that the
  dim must not disable editing; whether it should reach the mounted editor's paper
  is a judgement that wants a real board, not a number. (Review L1, reasoned from
  the draw code and never rendered.)
- **A region's dim barely moves the two surfaces that carry it most.** The wash is
  authored at 0.07/0.09 and `dimmedAlpha` takes a `min`, so it is left *unchanged*;
  the outline moves only 0.35→0.22 (light) / 0.30→0.22 (dark). For a bound-but-empty
  or collapsed region the only real signal left is the label. §4.1 accepted the
  collapsed case explicitly — this is the measurement behind that acceptance rather
  than a defect, and `dimmedOpacity` is the one knob if it reads wrong. (Review L2,
  confirmed from the authored alphas.)
