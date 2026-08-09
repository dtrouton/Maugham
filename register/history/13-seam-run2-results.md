# Phase 13 — Seam experiment, run 2

**Result: VOID again**, for a different and more interesting reason than run 1.

---

## 1. What was changed, and why it did not work

Run 1 was void because both agents had the project's `CLAUDE.md` — whose tripwire 14 states the
answer verbatim, 750ms figure and phantom-file consequence included — injected into their context.

For run 2 I changed **exactly one variable**. Same two briefs (byte-identical, still mechanically
diffed at Arm S = Arm B + 24 lines), same harness, same three scenarios, same signature. The only
difference: `CLAUDE.md` was physically moved out of the working tree **before** either agent was
spawned, and restored immediately after both finished. Integrity verified by SHA both sides
(`d9ed60db…`), and by `git status` reporting the file identical to HEAD on restore.

**It made no difference. Both agents still had it.**

> **Arm B:** *"My system context for this session contains the project's `CLAUDE.md` in full,
> injected before I received the task."*

> **Arm S:** *"injected by the harness before your message, not read by me. […] I complied with the
> letter of the 'read exactly one file' constraint — the only file I opened this session is
> `BRIEF.md`. But the constraint's intent was defeated before my turn began."*

### The mechanism

**Subagents inherit the parent session's project context; they do not re-read it at spawn time.**
My session loaded `CLAUDE.md` at startup, and every agent I dispatch inherits that snapshot. Editing
or deleting the file on disk afterwards is irrelevant — the contamination is upstream of the
filesystem.

This is worth stating as a general result, because it is not obvious and it silently invalidates a
whole class of experiment:

> **You cannot decontaminate a subagent by editing files. Any "blind implementer" experiment run
> via subagent dispatch from a session that has project instructions loaded is contaminated by
> construction, no matter what the subagent is told or permitted to read.**

Both Phase 10's regeneration and both seam runs were dispatched this way. Phase 10 was less exposed
— `CLAUDE.md` says nothing about `TreeWalk`'s internals — but it was not *clean*, and I should have
identified this mechanism then rather than after two void runs.

---

## 2. What run 2 produced anyway

All three scenarios passed for both arms, as in run 1.

| Mover | research-note debounce | open-manuscript autosave | registry clean |
|---|---|---|---|
| Shipping (control) | ✅ | ✅ | — |
| Naive (negative control) | **phantom** | **phantom** | — |
| Run 2 Arm B | ✅ | ✅ | ✅ |
| Run 2 Arm S | ✅ | ✅ | ✅ |

**One experimenter repair, disclosed:** run 2's Arm S omitted `@testable import Maugham`, which the
brief's template states explicitly. I added the line, annotated in-file as
`// EXPERIMENTER REPAIR`. Mechanical, not semantic — but it is a modification of an agent's output
and it is on the record.

### A finding that survives, and one that does not

**Does not survive: the destination-path hazard.** In run 1 I reported that *both* arms independently
derived that a `Document` open at the *destination* path must also be quiesced — a hazard the
shipping code does not handle — and I offered it as an uncontaminated signal that boundary claims
were doing real work. Across all four arm outputs:

| | quiesces destination |
|---|---|
| Run 1 Arm B | YES |
| Run 1 Arm S | YES |
| **Run 2 Arm B** | **NO** |
| Run 2 Arm S | YES |

Three of four. **It is not a reliable derivation, it is a coin-flip that landed heads twice.** My
run-1 claim that "both arms derived it" was true of run 1 and I generalised it into a property of
the claims. n=2 was not enough to say that, and I should not have said it. The underlying question —
*is the destination hazard real in the shipping code?* — is untouched by this and still worth a
ruling.

**Survives: the interface-satisfiability findings.** `CLAUDE.md` says nothing about either, and run
2's Arm S reached the folder-enumeration gap independently (run 2's Arm B did not mention it):

- **`S-S-02` is unsatisfiable against the given interface.** "Every project-relative path affected by
  a move" cannot be enumerated: `document(for:)` is exact-match, `Document` has no path, and
  `allOpenDocuments()` gives no path direction. The real system solves this at the *interface* —
  `relocateUserContent(affectedPaths:perform:)` makes the caller supply them.
- **`S-S-05` is unreachable.** I verified this myself in the source rather than taking it from an
  agent: `DebounceScheduler.flush()` is `async` and non-throwing, and the store's scheduler closure
  catches its own errors. So `flushPendingSave()` — declared `throws` — **cannot throw**. The claim
  "a flush failure MUST NOT abort the move… it is recorded" describes a scenario the API cannot
  produce. The shipping code wraps the call in a `do/catch` with an error log: **dead error
  handling**, written by someone who believed otherwise.

Two seam claims, both true-sounding, both load-bearing in prose, both unsatisfiable or unreachable
against the actual interface. Neither is findable by any test. Both were found by reading claims
against an interface — the same technique that beat 240,160 property cases in Phase 10.

---

## 3. What it would take to get an answer

The only reliable fix is **a fresh top-level session in a checkout with no project instructions** —
not a subagent, because subagents inherit. Concretely, one of:

1. **You run it.** Start a Claude Code session in a scratch directory containing only the brief (no
   `CLAUDE.md`, not inside this repo), paste the brief, and hand me the two files. That is the clean
   room; I cannot construct it from inside this session.
2. **Non-Claude implementer.** Any model without this repo's instructions in context.
3. **Abandon blind-implementation as the method** and lean on the technique that has actually been
   productive twice: **claim-versus-interface consistency review**, which is not contamination-
   sensitive in the same way — it finds gaps *in the artifact*, and knowing the codebase does not
   tell you that `S-S-02` is unsatisfiable or that `flushPendingSave` cannot throw.

My honest recommendation is (3), with (1) if you want the boundary-vs-seam question specifically
answered. Two void runs is enough evidence that this particular question is expensive to test from
inside the harness, while the consistency-review technique has produced five real findings across
three phases at a fraction of the cost.

---

## 4. Status of the boundary-vs-seam question

**Unanswered.** Both framings produced working code in both runs, but every run was contaminated on
exactly the question at issue — whether the relationship is *derivable* from the boundaries. Nothing
in Phases 11–13 licenses a conclusion either way, and I am not going to extract one from four
contaminated samples.

What the runs did establish, independent of contamination:

- The harness is sound and discriminating (validated against shipping and naive movers, both
  scenarios, both directions).
- The two briefs differ by exactly the intended section.
- The seam framing surfaced two claims that the interface cannot satisfy — which is an argument that
  **claims and interfaces are one artifact**, and the strongest thing to come out of this phase.

## 5. Artifacts

| Path | What |
|---|---|
| `seam-arms/run2-B/`, `seam-arms/run2-S/` | Run 2 implementations + notes + self-reports |
| `seam-arms/B/`, `seam-arms/S/` | Run 1, for comparison |
| `results/seam2-arm{B,S}.txt` | Run 2 logs |
| `12-seam-results.md` | Run 1 write-up (its destination-hazard claim is corrected here) |

Production files changed: **0**. `CLAUDE.md` restored and SHA-verified. Worktree removed.
