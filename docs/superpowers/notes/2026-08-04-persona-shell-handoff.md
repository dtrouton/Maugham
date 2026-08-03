# The persona shell — handoff after slice 3's implementation

*Written 2026-08-04, at the end of the session that flipped M1C, built slices 1
and 2, re-cut the right-pane registry, and took slice 3 to six of its eight
tasks. Paste the block below to start the next session.*

---

We are continuing the **persona shell**. The design is
`docs/superpowers/specs/2026-08-01-persona-shell-workflow-design.md` — read §4.1,
§5.0 and §6.1/§6.2 first; all three are amendments written *after* the original
draft and all three overturn something in it.

## State

`main` is at **`8795e3c`**. **Pushed only as far as `c3fc110`** — everything from
slice 3 is local. **No tag.** The paired Mac + phone release is still deferred by
choice until the shell work lands.

| Slice | State |
|---|---|
| 1 — the subject-picker | **done, smoked** |
| 2 — Plan's tree | **done, smoked** |
| — the right-pane audit | **done, smoked** (not a numbered slice; it came out of slice 2's smoke) |
| 3 — the canvas highlight | **6 of 8 tasks. Not reviewed.** |
| 4 — the Inspector dissolves | not started |
| 5 — synopsis folds into intent | not started |
| 6 — Review's posture | not started |
| 7 — research becomes a view | not started, **deliberately unspecced** |

## Do these first, in this order

**1. Slice 3 task 7 — the dim must be audible.** Not optional. ADR 0026 §10 is
the precedent and the argument: Claude's cards got a spoken term *because a lean
is inaudible*, and a dim is inaudible by the same argument. Two things it has to
get right, both recorded in the plan:

- **The AX rebuild triggers on `sceneRevision` alone today**, and lit-ness depends
  on the **subject** as well. Every label goes stale on a tree click unless it
  joins the same two-trigger shape `rebuildHighlight()` already uses.
- **Lit-ness is not a durable fact about the object** — it is window state that
  changes when the writer clicks a different row. The label builder's ordering
  rule is explicit (kind, name, provenance, then durable facts), so appending to
  that list is the wrong move; decide where it goes.
- **Do not implement the dim as a removal from the tree.** It is cheaper and it is
  available, and it makes the dim a *removal* for a VoiceOver user where it is a
  de-emphasis for a sighted one — while a dimmed card is still clickable.

**2. Slice 3 task 8 — the whole-branch review.** It has found a Critical in **ten
consecutive slices**, twice by finding the seam no task owned (slice 1: a
screenplay had no project row; slice 2: nothing produced the parsed script that
Plan's tree needs). Give it the ledger. **I would not push slice 3 without it.**

## Then, before slice 4 and slice 6 respectively

- **Issue #21** — a mint-race words-loss in `StatementEditorHost`, deliberately
  unfixed and owed a decision **before slice 4 touches that file**. The
  reconnaissance found it is **two mechanisms, not one**: `⌘⌥N`/`⌘⌥V` are separate
  `case` arms, so that route *tears the host down* and `release()` never runs. A
  fix aimed only at `release()` closes one of two. And the test that observes it
  **pins the loss as current behaviour** — a correct fix turns it red, which is the
  signal, not a regression.
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
- Baseline at `8795e3c`: **4236 Mac tests, 0 failures.** The two wall-clock MCP
  tests flake in-suite and pass in isolation — apply the discriminator before
  attributing a red run to your branch.
- A **Release** build before reporting if you touched a view.
- If `CanvasView`'s memberwise init changes, expect stale-`.o` `Undefined symbol`
  errors; CLAUDE.md's clean-DerivedData case is real and was hit twice.
- **Do not `git add -A` while a subagent is working.** `0c1930c` describes a spec
  change and carries 663 lines of code because I did.

## Smoke items still owed on slice 3

- Sweeping across a region bound to a **different** chapter does nothing at all —
  no bind, no region, no explanation — while the standing offer still says nothing
  is bound. Correct per the never-re-bind ruling, and the one gesture in this
  design with no confirmation of any kind.
- **Escape only reaches the canvas when the canvas has focus**, exactly like ⌫.
  Click a chapter in the tree and the keyboard is in the sidebar, so Escape there
  does nothing until one click lands on the canvas.
- A lit region that is **collapsed** lights one rectangle and no cards.
