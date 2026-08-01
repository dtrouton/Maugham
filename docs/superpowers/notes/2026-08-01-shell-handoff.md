# The persona shell — handoff

*Written 2026-08-01, at the end of the session that built, reviewed, merged and
pushed M1A and then audited the shell it landed in. Paste the block below to
start the next session.*

---

We're starting the **persona shell** work. The design is written and agreed;
**read it before anything else** — `docs/superpowers/specs/2026-08-01-persona-shell-workflow-design.md`.
It is sliced six ways and explicitly sequenced *after* M1A's smoke.

## State

`main` is at **`6873c19`**, **pushed**. Tree clean. **No tag** — M1A completed M1
in code, and the release is deliberately not cut.

- **M1A merged at `7b8e762`** (32 commits), plus three tidy commits closing its
  residuals. See `memory/project_milestone_1a_spine.md`.
- **M1C's roadmap entry is still `~`.** Every slice is ✓; the flip waits on the
  whole-milestone smoke. That is Denver's.
- **The paired Mac + phone release is owed and unstarted.** At manifest schema 4
  an older build *refuses* a project rather than degrading it, so the two ship
  together or not at all.

## What M1A still owes, before any of this starts

1. **The whole-milestone M1 smoke.** Denver runs it. The script is in the M1A
   memory file; the item no unit test can reach is the **iOS download gate for
   `intent.md`**, which sits at the *project root* — a directory level the phone
   has never read before.
2. **Flip M1C's `~` to ✓** once that smoke passes.
3. **Then** the paired release.

## Read these, in this order

1. **`docs/superpowers/specs/2026-08-01-persona-shell-workflow-design.md`** — the
   design. §2 is the rule; §5.1 is the Inspector's dissolution; §6 is the slicing.
2. **`docs/superpowers/specs/2026-07-25-mode-based-ux-redesign-design.md`** — the
   umbrella. The new spec is *an amendment in force* to its §6.3 matrix and §8
   bridge; everywhere else the umbrella stands.
3. **`MEMORY.md`** at `~/.claude/projects/-Users-denver-src-Maugham/memory/` —
   start with `project_milestone_1a_spine.md`, whose "what this milestone is
   actually evidence for" section is the process argument for how to run this.
4. **CLAUDE.md**'s hard invariants and tripwire table.

## The rule, in one line

> **Persona is the stage. The left segment selects the centre. The right column
> belongs to the persona — except in Review, where the columns follow the
> posture.**

Posture is **not** universal. An early draft said it was; the spec records the
correction. It is needed only where two jobs are done over the *same object* —
Review now, Author at M2.

## Six things that will bite

1. **Two slices touch what M1A just shipped.** Slice 4 removes
   `IntentAffordanceRow`; slice 5 folds synopsis into per-document intent. Both
   want a settled base, which is why nothing starts before the smoke.
2. **`StatementEditorHost.swift` has produced three Criticals and four
   Importants**, every one a value still trusted after the thing it described had
   moved — and *two of those were introduced by fixes that were themselves
   correct*. Slices 1–4 all touch it. **Ask "what does this change make newly
   possible?" as its own step, separate from "does it address the finding."** That
   question caught the last three.
3. **There is a grep census over `resolvedScope`'s readers** in
   `TripwireGrepTests`, with a planted-offender companion and a control. A new
   reader must be declared there with a reason. It does not cover values *other*
   than that marker — which is the honest limit of a token census.
4. **The project row deletes a workaround, and that is the point.**
   `StatementPane`'s `[Chapter | Project]` switch exists *only* because the tree
   cannot say "the project". That pane-local scope concept is what the reverted
   `Open`-sets-scope work collided with for three fix rounds. Slice 1 removes it.
5. **Removing `.inspector` from Publish before its Publishing section has a home
   deletes the writer's table-of-contents control.** An earlier draft of the spec
   proposed exactly that, on the strength of a `Persona.swift` comment giving a
   cosmetic reason for a pane doing real work. Slice ordering in §6 exists for
   this.
6. **`.synopsis` in `ReferenceTools`, `FountainNodeMapper` and
   `TranslationCoverage` is the Fountain element type**, not
   `StructureItem.synopsis`. An over-eager grep will eat it.

## A ruling still open, and it is a words-loss

Found by the tidy pass and deliberately **not** fixed, with a reason worth
respecting:

**Type into a scope that has no statement yet, then switch away before the file
exists, and the character is lost.** `reconcile` calls `target.release()` (which
clears `draft`) while the mint's load is still in flight; the mint then binds with
`carryingDraft: true` over an empty draft. Pre-existing, unchanged by the tidy,
and *observed* by the new test rather than inferred.

It was not fixed because the obvious fix — snapshot the draft at `mintAndBind`
and hand it to `bind` — **puts a second copy of the text beside the box**, which
is the shape tripwire 6 exists to prevent. It deserves its own think rather than
a ride-along. **Decide it before slice 4 touches that file.**

## How to run the slices — what earlier sessions paid for

- **Build the first slice before writing the later ones' plans.** M1A's
  re-derivation found **fourteen** wrong claims in text written against code that
  did not exist yet, four of which would have shipped silently.
- **A plan carries contracts, symptoms and verified signatures — never function
  bodies.** Quote a signature only if you read it out of the tree that day, and
  cite `file:line`.
- **Tell implementers that refusing a stated ruling they can falsify is the
  standard.** Eleven did it on M1A and every one was right — including one that
  disproved a claim in the spec, one that measured a platform assumption a doc
  comment had backwards, and one that overrode a controller deferral with a
  measurement.
- **Plant offenders, and treat a plant that does not fire as the finding.** That
  happened twice on M1A and both were real defects in the test rather than the
  code.
- **Reviewers write their verdict to a file before replying.** Agents went idle
  without reporting repeatedly.
- **The whole-branch review has found a Critical in every one of the last eight
  slices.** Give it the ledger.
- **No prose counts over lists.** Six were found on M1A; one was caught by its own
  author within the hour, one was written eleven lines below a comment saying
  "count the set, not this comment."

## Mechanical, each of which cost a task

- `./gen.sh` before any count you quote.
- **`-only-testing` suite paths are flat** — a folder-shaped path runs zero tests
  and exits 0, which reads exactly like green.
- **MaughamCore's own suites are run by NEITHER scheme** — reach them with
  `cd Packages/MaughamCore && swift test`. CLAUDE.md's build-flow section calls
  the Mac scheme "Mac app + MaughamCore", which is true of the build and false of
  the tests. **That drift is still unfixed and is owed a correction.**
- Three MCP tests are wall-clock dependent; they fail under a loaded suite and
  pass in isolation. Apply the discriminator before believing a red run is yours.
- A Release build before reporting, if you touched a view.
