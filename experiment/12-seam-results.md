# Phase 12 — Seam experiment: boundary claims vs seam claims

**Result: VOID on the central question.** Both arms were contaminated by an injected `CLAUDE.md`
containing tripwire 14 verbatim. Read §1 before anything else.

---

## 1. The experiment failed, and the failure is the finding

**Design.** Two briefs differing by exactly one section. Arm B carried 13 boundary claims and 4
boundary intent clauses — each API member described in isolation, *including* that both 750ms
debounces exist and that `scheduleFileSave` targets the path supplied at schedule time. Arm S was
generated mechanically from Arm B by adding §3b: eight **relationship** and **graph** claims naming
the three-party race and the ordering requirement. The generator asserts the diff:
**Arm S = Arm B + 24 lines, − 3 lines**, the removals being only filename swaps.

**Question.** Is the relationship derivable from the boundaries, or must it be its own object?

**What happened.** Both arms produced correct implementations. Both passed all three scenarios. On
the face of it: *boundary claims suffice, Arm B derived the hazard from S-B-04/05/08 alone.*

**That conclusion is worthless.** Both agents, asked to self-report, disclosed that the session had
injected the project's `CLAUDE.md` into their context before they read anything — and tripwire 14
states the answer outright, including the 750ms figure and the phantom-file consequence.

> **Arm B:** *"I knew the answer before I read the claims. […] I cannot honestly assert that a
> version of me without the injected context would have connected 'the Document captured its URL at
> load time' to 'therefore close it before moving' as quickly, or at all. Treat my arm's result as
> contaminated on the central question."*

> **Arm S:** *"the central insight the brief was presumably testing whether I would derive was
> already sitting in my context in compressed form when I started."*

My isolation measures — staging each brief in a `/tmp` directory with no `CLAUDE.md`, forbidding
all repository access, instructing each agent to disregard injected project knowledge — **all failed
for the same reason: `CLAUDE.md` is injected at session start, before any instruction of mine can
take effect.** Neither agent read a single repository file. It did not matter.

**The self-report is what saved this.** Without it I would have reported a clean, confident, and
false positive: *"boundary claims are sufficient — the control arm derived the seam rule unaided."*
That is exactly the result you would want to be true, which is what makes it dangerous. The
mechanism that caught it cost three sentences in a prompt.

### The uncontaminated residue

Two things survive, because `CLAUDE.md` says nothing about either and both agents said so explicitly:

1. **The destination-path hazard.** Both arms close and unregister the `Document` at the
   *destination* path as well as the source, reasoning from `S-B-08` alone: a Document open at
   `newPath` captured that URL at load time and would autosave its stale text over the freshly-moved
   bytes. **The shipping code does not do this.** Whether it is a real gap or unreachable in
   practice is a ruling; it was derived from boundary claims by both arms.
2. **`S-S-02` is unsatisfiable against the interface I gave** — see §3, the strongest finding here.

---

## 2. What did run, and what it showed

The harness is sound even though the arms are not. It was validated in **both** directions before
either arm ran — a test that cannot fail proves nothing.

| Mover | research-note debounce | open-manuscript autosave | registry clean |
|---|---|---|---|
| **Shipping** (`relocate` / `relocateUserContent`) — control | no phantom ✅ | no phantom ✅ | — |
| **Naive** coordinated move — negative control | **phantom** ✅ | **phantom** ✅ | — |
| **Arm B** (boundary claims) | no phantom | no phantom | ✅ |
| **Arm S** (seam claims) | no phantom | no phantom | ✅ |

Both scenarios are real and distinct: one arms the store's path-keyed `scheduleFileSave`, the other
loads a real `Document` and types into it so its own internal timer is armed against the URL it
captured at load. A mover that closes the Document but forgets the flush fails the first; one that
flushes but forgets to close fails the second. Both arms handled both.

### Where the arms differed from each other and from shipping

| | Shipping | Arm B | Arm S |
|---|---|---|---|
| Order | close+unregister, then flush | **flush, then** close+unregister | close+unregister, then flush |
| Flush failure | logged, move proceeds | **`try` — aborts the move** | logged, move proceeds |
| Destination path quiesced | no | **yes** | **yes** |

Arm B's flush-before-close ordering and its abort-on-flush-failure both diverge from shipping, and
**neither is caught by any test** — mine or the repo's. Arm S got both right because `S-S-05`
(flush failure must not abort the move) and the ordering discussion were stated for it. That is a
real difference the seam claims produced, and it is invisible to the harness: the only reason I know
about it is that I read the two implementations side by side.

That is worth stating plainly. **On the one measurable axis the arms tied; on an axis I could only
see by reading, the seam claims did better.** A cleaner experiment would force a flush failure.

---

## 3. The strongest finding: a seam claim the interface cannot satisfy

Arm S's first ambiguity, quoted:

> **a1.** *"'Every project-relative path affected by a move' (S-S-02) is not enumerable with the
> given API. S-S-03 explicitly contemplates 'notes under a moved folder', which means the spec
> anticipates that a move can affect paths other than `oldPath`. But the `DocumentStore` surface
> offers no way to enumerate them: `document(for:)` is exact-match, `allOpenDocuments()` returns
> `[Document]`, and `Document` has no knowledge of its own project-relative path. So there is no
> `Document -> path` direction, and therefore **no way to close the documents open beneath a moved
> folder**. I implemented exact-path quiescing only and am flagging the folder case as
> unimplementable from this brief."*

Arm B reached the same wall independently.

**This is correct, and the real system solves it at the interface.** The shipping entry point is
`relocateUserContent(affectedPaths: [String], perform:)` — **the caller supplies the affected
paths**, precisely because the mover cannot derive them. My brief's signature
`move(from:to:in:)` omits that parameter, so the discipline the seam claims mandate is
unimplementable against the interface I handed over.

The lesson generalises past this experiment: **a seam claim can be true, well-stated, load-bearing —
and unsatisfiable, because the interface does not carry the information the claim requires.** The
claims and the interface are one artifact, not two. Neither arm could have written correct code for
the folder case at any level of claim quality, and both said so rather than faking it.

---

## 4. What I would change to get an answer

1. **Fix the contamination.** The only reliable route is an inferrer with no project context at all
   — a separate process, or a repository checkout with no `CLAUDE.md`, not an instruction to
   disregard one already in context. Everything else is theatre.
2. **Pick a seam whose rule is NOT in `CLAUDE.md`.** Prior knowledge cannot help with a rule that
   was never written down. Better still, pick one where the *correct* answer differs from the
   documented rule, so contamination pushes toward the wrong answer and a right answer is evidence.
3. **Force a flush failure**, so the `S-S-05` divergence becomes a test result rather than something
   I only noticed by reading.
4. **Give the arms the real signature** (`affectedPaths:`), or leave it out deliberately and make
   §3's unsatisfiability the measured outcome rather than a side finding.

---

## 5. Artifacts

| Path | What |
|---|---|
| `11-seam-brief-BOUNDARY.md` / `11-seam-brief-SEAM.md` | The two arms' briefs |
| `scripts/11-build-seam-briefs.py` | Derives Arm S from Arm B; asserts the diff |
| `seam-arms/B/`, `seam-arms/S/` | Each arm's implementation and notes, incl. self-reports |
| `seam-harness/` | Control, negative control, and arm tests |
| `results/seam-*.txt` | Run logs |

Production files changed: **0**. The harness lived in a throwaway worktree, now removed.
