# The compiler's second draft — the declared world and the two jobs

*Brainstormed 2026-08-07 with Denver, after his first real smoke of M2's loop.
This spec **supersedes the workflow half** of
`2026-08-04-m2-author-compiler-design.md` — the note vocabulary, the fates,
the answer flow, the drift mechanism, and the pane's organization. It **keeps
the mechanism half unchanged**: the warm session, the delta and marker, the
confinement, the per-device sidecar, the run command, promote-to-task's
plumbing, and every teardown rule. Where the two documents disagree about
workflow, this one governs.*

---

## 1. The finding that forced this

Denver, smoking the shipped loop: *"It's not clear why this is different from
annotations when I hit it as a user"* and *"the line I add being dropped into
intent with no clarification as to why is wonky."* Both trace to one root:
**the spine's second half was never built.** The umbrella defined intent as
freeform prose *"with Claude deriving the checkable structure"* — M1 shipped
the prose and the history; the derived structure was skipped; M2's compiler
therefore consumed intent as a blob and produced literary commentary. A
compiler with nothing declared to check against is a fast review — which is
annotations with a different lifecycle, and lifecycle is invisible at first
contact.

## 2. What the loop is, in editorial terms

Real editorial practice separates levels (developmental / line / copy /
proof) and keeps two continuous, delta-shaped functions running underneath
them: the **style sheet / bible** (facts, voices, timeline, knowledge states
— who knows what, since when) and the **first reader**. Established
non-prescriptive feedback theory converges on the same posture: Elbow's
*movies of the reader's mind* (report what happened in the reader, not
judgments), Gardner's *vivid and continuous dream* (flag where the trance
broke), Lerman's Critical Response Process (neutral questions before
opinions; opinions by permission), and the writers'-room maxim *note the
problem, never the solution*.

So the loop has **two jobs, and neither is a critic**:

- **Continuity editor** — checks the wet ink against the *declared world*:
  the writer's intent clauses, their rules ("Kelly only acts on what she has
  heard"), and the bible's facts and knowledge states. Every note cites the
  declaration or the establishing ¶ it checks against.
- **First reader** — reports reader experience on the wet ink: where the
  dream broke, what a reader believes at this point, as experience and
  neutral questions.

**All judgment is evicted to Review** (M3's named passes, the durable
adjudicated loop). That eviction — not the pane, not the lifecycle — is what
finally makes diagnostics *feel* unlike annotations: annotations are opinions
you adjudicate; diagnostics are facts about your declarations and reports of
a reader's experience. Developmental feedback is explicitly refused by the
loop: it needs the whole, and it belongs to Review.

## 3. The declared world

### 3.1 Two kinds of truth

**Writer-declared truth** lives where M1 put it: freeform prose in statement
documents, plain markdown on disk, op-logged. Intent essays as today. Rules
are just sentences in the same prose ("Kelly only ever acts on things she's
actually heard") — a rule is intent about a character. No forms, ever.

**Derived structure** is Claude's reading of that prose into checkable units
— *clauses* and *rules* — cached under `.maugham/` (per-device, beside the
diagnostics sidecar), re-derived when the source statement's text hash
changes. Disposable, never sacred, never shown as mechanics: the pane quotes
the writer's own sentences as the things being checked.

**The bible** is the second derived store: facts the manuscript establishes —
knowledge states (who learned what, at which ¶), physical/timeline facts,
voice notes — each carrying its establishing ¶id. Nobody hand-maintains it:
**each run indexes the wet ink while checking it** (§5's fact-candidates).
Cache, not truth; deleting it costs one re-read.

### 3.2 Rulings — decisions as a stratum of the statement

A statement document grows an internal shape: the **essay** (the freeform
intent, untouched — what the strip quotes) and a **Rulings** section — a
plain markdown list, one ruling per line, dated, with provenance: *"Kelly
heard about the call offstage, before scene 4 — ruled 7 Aug, from a run on
¶wnse."* Still one human-readable file per scope; still only the writer's
words. Because it is an op-logged document: **⌘Z undoes a ruling, History
shows when it was ruled, Rewind shows the declared world as of any draft** —
the statement architecture paying off. The Rulings parser is forgiving of
hand edits (the palette-card pattern: derived rendering over writer-editable
markdown).

### 3.3 One surface

The Intent pane grows into the declared world's surface — **not** a new pane.
Three strata, visibly different:

- **Intent** — the essay, edited as today.
- **Rulings** — itemized rows: date, provenance, *edit* and *revoke* on the
  row. Revoke deletes the line (one undo step); the derivation cache
  re-derives; checks stop firing immediately.
- **Bible** — derived entries in a visibly provisional register (the
  derived-stratum styling; the canvas's "straight means Claude" instinct
  applied to a pane), each with its establishing ¶. Three actions: **bless**
  (graduates to a ruling — moves up a stratum, becomes the writer's, dated),
  **correct** (one-line edit landing as a ruling), **dismiss** (entry dies;
  may return if the manuscript re-establishes it).

Scope resolves as intent already does (piece first, project fallback).
"How do I see what I decided" = open the pane, read Rulings. "How do I
revoke" = delete a line of my own document.

### 3.4 The membrane, tightened

Nothing enters the writer-owned layer except through **bless / correct /
rule / the writer's own editing** — an explicit act on visible text. Claude's
derivations live only in caches that decay. This is stricter than the shipped
answer flow (which appended a chat reply verbatim); ADR 0027 gains a
paragraph placing the derived bible as a new kind of Claude-produced
artifact: persistent cache of readings, subordinate stratum, never truth
until blessed.

## 4. The writer's experience (normative, not illustrative)

- Declares almost nothing up front; adds a sentence to intent when a rule
  firms up.
- ⌘R as today. The pane reads as a report: **conformance summary first**
  (the writer's clauses quoted, each *holds / strains / silent*, strains
  citing the ¶ and what pulls), then **continuity questions** (each citing
  the establishing ¶, ending as a question — "learned offstage, or slip?"),
  then the **reader's report** (dream-breaks and belief statements, capped
  small).
- Answering a question is **ruling**: a click on an offered answer or a typed
  word of the writer's own; the pane names the destination as it lands
  ("added to this piece's rulings: …"); one undo.
- Ignoring anything remains free — next run replaces.
- The bible grows silently behind the writing; it is inspected in the pane's
  bible stratum, never tended.
- First run on an existing manuscript: one refusable offer — *"I haven't
  read this piece. Read it whole and take notes?"* On-demand, never
  background, never re-asked as a nag.
- **Drift is a pattern, not a note kind**: a clause straining the same way
  across consecutive runs surfaces as the summary's top line — "your line
  may have moved; draft's right, or intent's right?" — computed from the run
  records the sidecar already keeps.

## 5. The run, rebuilt on the same machinery

Unchanged: warm session, delta/marker (including the wet-ink flush), model
gear, confinement (`--tools ""` + enumerated allowlist), per-device sidecar,
teardown rules, promote-to-task plumbing, the ⌘R command and flash.

**Context in**: the delta as today; the derived clauses/rules; the bible
sliced by the subjects appearing in the delta (keyed by fact subjects — a
run about Kelly's scene carries Kelly's facts, not the ledger).

**Output contract** — four schema-pinned sections:

1. **Conformance** — per clause/rule: holds / strains / silent; strains cite
   ¶ + one sentence of what pulls. Never a fix.
2. **Continuity** — violations of facts/rules, each citing the establishing
   ¶, phrased as a question.
3. **Reader report** — dream-breaks (¶ + what happened in the reader) and
   belief statements; capped small.
4. **Fact-candidates** — what the wet ink established; land silently in the
   bible cache; never rendered as notes.

**Register enforced structurally**: the schema has no severity field and no
suggestion field — nowhere for "you should" to go. A planted-offender test
feeds a fix-shaped body and ingest refuses it.

**Removed from the shipped design**: the free-form category tag; the drift
diagnostic as a special kind; the free-text "that's deliberate…" reply on
arbitrary notes (deliberateness is expressed by ruling or ignoring).

**The fates**: fix (self-dismissal, unchanged) · ignore (replace-on-run,
unchanged) · **answer → ruling** (questions only, visible destination) ·
promote-to-task (unchanged plumbing; body cites the section it came from).

## 6. What this hands M3

Judgment has exactly one home, so Review's named passes stop competing with
the fast loop for identity. Review inherits: the declared world as context
every pass reads (a developmental pass opens with the writer's clauses and
rulings), and the bible as the copyedit pass's style sheet.

## 7. Constitution check

- Output location: pane only; nothing in the editor or its chrome
  (ADR 0027 unchanged in substance, extended per §3.4).
- On-demand only: the bible grows only when runs run; the cold-start read is
  one refusable offer; drift is computed from records, never a background
  process.
- Modes/lenses: nothing is gated on declaring anything; an empty declared
  world means the conformance section is absent and the reader report still
  runs — absence is valid and mints nothing.
- Plain text: statements stay human-readable markdown; all derived stores
  under `.maugham/`.

## 8. Sequencing

**Spike first, small**: one measured run proving derivation quality (clauses
from Denver's real Tribute intent) and the four-section contract on the real
piece. The design leans on Claude deriving *good* clauses from real writer
prose — a claim to measure, not assume.

Then one milestone, three ordered stages:

1. **The declared world** — derivation layer (hash-cached), Rulings format +
   forgiving parser, the Intent pane's three strata, bless/correct/revoke.
   Provable without touching the run.
2. **The run rebuilt** — four-section contract, bible cache +
   fact-candidates, subject-sliced context, reorganized pane, reworked
   fates, structural register enforcement.
3. **Cold start + drift-as-pattern + docs** — the read-it-whole offer, the
   straining-pattern summary, guide rewritten around the two jobs, ADR 0027
   amendment.

Whole-branch review; merge to local main; no push, no tag — the paired
release gate is unchanged.

## 9. Out of scope

- Developmental feedback in the loop — refused by design, Review's job.
- Any form-based declaration UI.
- Hand-maintained bible editing beyond bless/correct/dismiss.
- Cross-piece bible aggregation (a character shared across pieces reads
  per-scope for now; revisit with M3).
- Phone surfaces.
