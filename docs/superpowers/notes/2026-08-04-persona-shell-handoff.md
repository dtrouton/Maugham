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

`main` is at **`860a679`**. **Pushed only as far as `c3fc110`** — everything from
slice 3 is local, and it should stay local until the smoke passes. **No tag.**
The paired Mac + phone release is still deferred by choice until the shell work
lands.

| Slice | State |
|---|---|
| 1 — the subject-picker | **done, smoked** |
| 2 — Plan's tree | **done, smoked** |
| — the right-pane audit | **done, smoked** (not a numbered slice; it came out of slice 2's smoke) |
| 3 — the canvas highlight | **done, reviewed, findings fixed. Not smoked.** |
| 4 — the Inspector dissolves | not started |
| 5 — synopsis folds into intent | not started |
| 6 — Review's posture | not started |
| 7 — research becomes a view | not started, **deliberately unspecced** |

## Do this first

**Smoke slice 3.** It is code-complete, reviewed and green (**4249 Mac tests, 3
failures — the two known wall-clock MCP flakes, 0 in isolation**; Release build
succeeded), and it has never been run by a human. The smoke list is at the bottom
of this note and it is longer than usual: two of its items are judgement calls
the review deliberately declined to settle from the alpha values.

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

## Then, before slice 4 and slice 6 respectively

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
- **A deleted item leaves the window's subject dangling, at three sites and only
  one of them repairs it.** Found by slice 3's fix round while checking M2's blast
  radius, and **wider than the review filed it**. `BinderView.subject(_:afterDeleting:)`
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
- **§5's palette / visual-language contradiction** — the three-column table and
  the "Leaving, by persona" list disagree. Recorded with the delta list as
  normative; **slice 6 must confirm rather than inherit that reading.**

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

## Smoke items still owed on slice 3 — and one on issue #21

**Issue #21, and it is one gesture:** open the Intent pane (`⌘⌥N`) on a chapter
with **no intent yet**, type one character, and *immediately* click another
chapter — do not wait. Come back. The character should be there. Then the same
thing with `⌘⌥V` instead of the click, which is the door that tears the host down
rather than the one that calls `release()`. Worth doing twice because the two
routes were separate defects and only one of them was in the original diagnosis.


- Sweeping across a region bound to a **different** chapter does nothing at all —
  no bind, no region, no explanation — while the standing offer still says nothing
  is bound. Correct per the never-re-bind ruling, and the one gesture in this
  design with no confirmation of any kind.
- **Escape only reaches the canvas when the canvas has focus**, exactly like ⌫.
  Click a chapter in the tree and the keyboard is in the sidebar, so Escape there
  does nothing until one click lands on the canvas.
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
